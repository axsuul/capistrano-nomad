def capistrano_nomad_docker_image_types_manifest_path
  shared_path.join("docker-image-types.json")
end

def capistrano_nomad_read_docker_image_types_manifest
  manifest = {}

  on(roles(:manager)) do |_host|
    # Ensure file exists
    execute("mkdir -p #{shared_path}")
    execute("touch #{capistrano_nomad_docker_image_types_manifest_path}")

    output = capture "cat #{capistrano_nomad_docker_image_types_manifest_path}"

    unless output.blank?
      manifest = JSON.parse(output)
    end
  end

  capistrano_nomad_deep_symbolize_hash_keys(manifest)
end

def capistrano_nomad_update_docker_image_types_manifest(image_type, properties = {})
  on(roles(:manager)) do |_host|
    # Read and update manifest
    manifest = capistrano_nomad_read_docker_image_types_manifest
    manifest[image_type] = (manifest[image_type] || {}).merge(properties.stringify_keys)

    io = StringIO.new(JSON.pretty_generate(manifest))

    # Write to manifest
    upload!(io, capistrano_nomad_docker_image_types_manifest_path)
  end
end

def capistrano_nomad_build_docker_image_alias(image_type, ref)
  # Define nomad_docker_image_alias has a proc to return image alias
  fetch(:nomad_docker_image_alias).call(image_type: image_type, ref: ref)
end

# Fetch image alias from manifest
def current_docker_service_image_alias(image_type)
  image_alias =
    capistrano_nomad_read_docker_image_types_manifest
      .try(:[], image_type.to_sym)
      .try(:[], :image_alias)

  return image_alias if image_alias

  capistrano_nomad_build_docker_image_alias(image_type, capistrano_nomad_fetch_git_commit_id)
end

# Builds docker image from image type
#
# @param image_type [String, Symbol]
def capistrano_nomad_build_docker_image(image_type, path, *args)
  run_locally do
    git_commit_id = capistrano_nomad_fetch_git_commit_id

    [
      capistrano_nomad_build_docker_image_alias(image_type, git_commit_id),
      capistrano_nomad_build_docker_image_alias(image_type, "latest"),
      "trunk/#{fetch(:stage)}/#{image_type}:latest",
    ].each do |tag|
      args << "--tag #{tag}"
    end

    # If any of these files exist then we're in the middle of rebase so we should interrupt
    if ["rebase-merge", "rebase-apply"].any? { |f| File.exist?("#{fetch(:git).dir.path}/.git/#{f}") }
      raise StandardError, "still in the middle of git rebase, interrupting docker image build"
    end

    system "docker build #{args.join(' ')} #{path}"
  end
end

def capistrano_nomad_build_docker_image_for_type(image_type)
  image_type = image_type.to_sym

  attributes = fetch(:nomad_docker_image_types)[image_type]

  return unless attributes

  args = [
    # Ensure images are built for x86_64 which is production env otherwise it will default to local development env
    # which can be arm64 (Apple Silicon)
    "--platform linux/amd64",
  ]

  build_args =
    if attributes[:build_args].is_a?(Proc)
      proc_args = attributes[:build_args].arity == 1 ? [capistrano_nomad_fetch_git_commit_id] : []

      attributes[:build_args].call(*proc_args)
    else
      attributes[:build_args]
    end

  if (target = attributes[:target])
    args << "--target #{target}"
  end

  (build_args || []).each do |key, value|
    args << "--build-arg #{key}=#{value}"
  end

  capistrano_nomad_build_docker_image(image_type, attributes[:path], args)
end

def capistrano_nomad_push_docker_image_for_type(image_type, is_manifest_updated: true)
  # Allows end user to add hooks
  invoke("nomad:docker_images:push")

  run_locally do
    git_commit_id = capistrano_nomad_fetch_git_commit_id
    revision_image_alias = capistrano_nomad_build_docker_image_alias(image_type, git_commit_id)
    latest_image_alias = capistrano_nomad_build_docker_image_alias(image_type, "latest")

    [revision_image_alias, latest_image_alias].each do |image_alias|
      # We should not proceed if image cannot be pushed
      unless system("docker push #{image_alias}")
        raise StandardError, "Docker image push unsuccessful!"
      end
    end

    return unless is_manifest_updated

    # Update image type manifest
    capistrano_nomad_update_docker_image_types_manifest(image_type,
      ref: git_commit_id,
      image_alias: revision_image_alias
    )
  end
end
