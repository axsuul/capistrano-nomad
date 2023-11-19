class CapistranoNomadDockerPushImageInteractionHandler
  def initialize(*args)
    @last_digest = nil
  end

  def on_data(_command, stream_name, data, channel)
    if (match = data.match(/digest: ([^\s]+)/))
      @last_digest = match[1]
    end
  end

  def last_digest
    @last_digest
  end
end

def capistrano_nomad_docker_image_types_manifest_path
  shared_path.join("docker-image-types.json")
end

def capistrano_nomad_read_docker_image_types_manifest
  manifest = {}

  on(roles(:manager)) do |_host|
    # Ensure file exists
    execute("mkdir -p #{shared_path}")
    execute("touch #{capistrano_nomad_docker_image_types_manifest_path}")

    output = capture("cat #{capistrano_nomad_docker_image_types_manifest_path}")

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

def capistrano_nomad_build_docker_image_alias(image_type)
  image_alias = fetch(:nomad_docker_image_types).dig(image_type, :alias)
  image_alias = image_alias.call(image_type: image_type) if image_alias&.is_a?(Proc)

  raise StandardError, ":alias not defined for #{image_type}" unless image_alias

  # Add :latest if there's no tag
  image_alias << ":latest" if image_alias.split(":").count == 1

  image_alias
end

# Builds docker image from image type
#
# @param image_type [String, Symbol]
def capistrano_nomad_build_docker_image_for_type(image_type)
  image_type = image_type.to_sym
  attributes = fetch(:nomad_docker_image_types)[image_type]

  return unless attributes

  # No need to build if there's no path
  return unless attributes[:path]

  args = [
    # Ensure images are built for x86_64 which is production env otherwise it will default to local development env
    # which can be arm64 (Apple Silicon)
    "--platform linux/amd64",
  ]

  if (target = attributes[:target])
    args << "--target #{target}"
  end

  build_args = attributes[:build_args]
  build_args = build_args.call if build_args&.is_a?(Proc)

  (build_args || []).each do |key, value|
    args << "--build-arg #{key}=#{value}"
  end

  run_locally do
    # If any of these files exist then we're in the middle of rebase so we should interrupt
    if ["rebase-merge", "rebase-apply"].any? { |f| File.exist?("#{capistrano_nomad_git.dir.path}/.git/#{f}") }
      raise StandardError, "Still in the middle of git rebase, interrupting docker image build"
    end

    image_alias_args = args.dup

    [capistrano_nomad_build_docker_image_alias(image_type)]
      .compact
      .each do |tag|
        image_alias_args << "--tag #{tag}"
      end

    execute("docker build #{image_alias_args.join(' ')} #{capistrano_nomad_root.join(attributes[:path])}")
  end
end

def capistrano_nomad_push_docker_image_for_type(image_type, is_manifest_updated: true)
  attributes = fetch(:nomad_docker_image_types)[image_type]
  alias_digest = attributes&.dig(:alias_digest)

  run_locally do
    # Don't push Docker image if alias digest is already passed in
    unless alias_digest
      interaction_handler = CapistranoNomadDockerPushImageInteractionHandler.new
      image_alias = capistrano_nomad_build_docker_image_alias(image_type)

      # We should not proceed if image cannot be pushed
      unless execute("docker push #{image_alias}", interaction_handler: interaction_handler)
        raise StandardError, "Docker image push unsuccessful!"
      end

      return unless is_manifest_updated

      # Has the @sha256:xxxx appended so we have the ability to also target by digest
      alias_digest = "#{image_alias}@#{interaction_handler.last_digest}"
    end

    # Update image type manifest
    capistrano_nomad_update_docker_image_types_manifest(image_type,
      alias: image_alias,
      alias_digest: alias_digest,
    )
  end
end
