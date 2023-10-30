require "active_support/core_ext/string"
require "sshkit/interactive"

class CapistranoNomadErbNamespace
  def initialize(context:, vars: {})
    @context = context

    vars.each do |key, value|
      instance_variable_set("@#{key}", value)
    end
  end

  # Use default value passed in unless `nomad_job_task_cpu_resource` is set
  def build_nomad_job_task_cpu_resource(default:)
    nomad_job_task_cpu_resource == "null" ? default : nomad_job_task_cpu_resource
  end

  # Use default value passed in unless `nomad_job_task_memory_resource` is set
  def build_nomad_job_task_memory_resource(default:)
    nomad_job_task_memory_resource == "null" ? default : nomad_job_task_memory_resource
  end

  # rubocop:disable Style/MissingRespondToMissing
  def method_missing(name, *args)
    instance_variable = "@#{name}"

    # First try to see if it's a variable we're trying to access which is stored in an instance variable otherwise try
    # to see if there's a local method defineds
    if instance_variable_defined?(instance_variable)
      instance_variable_get(instance_variable)
    elsif respond_to?(name)
      send(name, *args)
    end
  end
  # rubocop:enable Style/MissingRespondToMissing
end

def capistrano_nomad_ensure_absolute_path(path)
  path[0] == "/" ? path : "/#{path}"
end

def capistrano_nomad_build_file_path(parent_path, basename, namespace: nil)
  segments = [parent_path]
  segments << namespace if namespace
  segments << "#{basename}.hcl"

  segments.join("/")
end

def capistrano_nomad_build_base_job_path(*args)
  capistrano_nomad_build_file_path(fetch(:nomad_jobs_path), *args)
end

def capistrano_nomad_build_base_var_file_path(*args)
  capistrano_nomad_build_file_path(fetch(:nomad_var_files_path), *args)
end

def capistrano_nomad_build_local_path(path)
  local_path = capistrano_nomad_root.join(path)

  # Determine if it has .erb appended or not
  found_local_path = [local_path, "#{local_path}.erb"].find { |each_local_path| File.exist?(each_local_path) }

  raise StandardError, "Could not find local path: #{path}" unless found_local_path

  found_local_path
end

def capistrano_nomad_build_local_job_path(name, *args)
  capistrano_nomad_build_local_path(capistrano_nomad_build_base_job_path(name, *args))
end

def capistrano_nomad_build_local_var_file_path(name, *args)
  capistrano_nomad_build_local_path(capistrano_nomad_build_base_var_file_path(name, *args))
end

def capistrano_nomad_build_release_job_path(*args)
  "#{release_path}#{capistrano_nomad_ensure_absolute_path(capistrano_nomad_build_base_job_path(*args))}"
end

def capistrano_nomad_build_release_var_file_path(*args)
  "#{release_path}#{capistrano_nomad_ensure_absolute_path(capistrano_nomad_build_base_var_file_path(*args))}"
end

def capistrano_nomad_run_nomad_command(kind, *args)
  converted_args = args.each_with_object([]) do |arg, collection|
    # If hash then convert it as options
    if arg.is_a?(Hash)
      arg.each do |key, value|
        next unless value

        option = "-#{key.to_s.dasherize}"

        # Doesn't need a value if it's just meant to be a flag
        option << "=#{value}" unless value == true

        collection << option
      end
    else
      collection << arg
    end
  end

  # Ignore errors
  public_send(kind, :nomad, *converted_args, raise_on_non_zero_exit: false)
end

def capistrano_nomad_execute_nomad_command(*args)
  on(roles(:manager)) do |host|
    run_interactively(host) do
      capistrano_nomad_run_nomad_command(:execute, *args)
    end
  end
end

def capistrano_nomad_capture_nomad_command(*args)
  output = nil

  on(roles(:manager)) do |host|
    output = capistrano_nomad_run_nomad_command(:capture, *args)
  end

  output
end

def capistrano_nomad_exec_within_job(name, command, namespace: nil, task: nil)
  on(roles(:manager)) do
    task = name unless task

    # Find alloc id that contains task
    output = capistrano_nomad_capture_nomad_command(
      :job,
      :allocs,
      { namespace: namespace, t: "'{{range .}}{{ .ID }},{{ .TaskGroup }}|{{end}}'" },
      name,
    )
    alloc_id = output.split("|").map { |s| s.split(",") }.find { |_, t| t == task.to_s }&.first

    if alloc_id
      capistrano_nomad_execute_nomad_command(
        :alloc,
        :exec,
        { namespace: namespace, task: task },
        alloc_id,
        command,
      )
    else
      # If alloc can't be determined then choose at random
      capistrano_nomad_execute_nomad_command(
        :alloc,
        :exec,
        { namespace: namespace, job: true },
        task,
        command,
      )
    end
  end
end

def capistrano_nomad_upload_file(local_path:, remote_path:, erb_vars: {})
  docker_image_types = fetch(:nomad_docker_image_types)
  docker_image_types_manifest = capistrano_nomad_read_docker_image_types_manifest

  # Merge manifest into image types
  docker_image_types_manifest.each do |manifest_image_type, manifest_attributes|
    docker_image_types[manifest_image_type]&.merge!(manifest_attributes) || {}
  end

  # Parse manifest files using ERB
  erb = ERB.new(File.open(local_path).read, trim_mode: "-")

  final_erb_vars = {
    git_commit_id: fetch(:current_revision) || capistrano_nomad_git_commit_id,
    docker_image_types: docker_image_types,
  }

  # Add global ERB vars
  final_erb_vars.merge!(fetch(:nomad_erb_vars) || {})

  # Add job-specific ERB vars
  final_erb_vars.merge!(erb_vars)

  # We use a custom namespace class so that we can include helper methods into the namespace to make them available for
  # template to access
  namespace = CapistranoNomadErbNamespace.new(
    context: self,
    vars: final_erb_vars,
  )
  erb_io = StringIO.new(erb.result(namespace.instance_eval { binding }))

  on(roles(:manager)) do
    execute(:mkdir, "-p", File.dirname(remote_path))
    upload!(erb_io, remote_path)
  end
end

def capistrano_nomad_fetch_job_options(name, *args, namespace: nil)
  fetch(:nomad_jobs).dig(namespace, name.to_sym, *args)
end

def capistrano_nomad_fetch_job_var_files(name, *args)
  capistrano_nomad_fetch_job_options(name, :var_files, *args) || []
end

def capistrano_nomad_fetch_jobs_names_by_namespace
  fetch(:nomad_jobs).transform_values(&:keys)
end

def capistrano_nomad_fetch_jobs_docker_image_types(names, namespace: nil)
  names.map { |n| fetch(:nomad_jobs).dig(namespace, n.to_sym, :docker_image_types) }.flatten.compact.uniq
end

def capistrano_nomad_build_jobs_docker_images(names, *args)
  image_types = capistrano_nomad_fetch_jobs_docker_image_types(names, *args)

  return false if image_types.empty?

  image_types.each { |i| capistrano_nomad_build_docker_image_for_type(i) }
end

def capistrano_nomad_push_jobs_docker_images(names, *args)
  image_types = capistrano_nomad_fetch_jobs_docker_image_types(names, *args)

  return false if image_types.empty?

  image_types.each { |i| capistrano_nomad_push_docker_image_for_type(i) }
end

def capistrano_nomad_assemble_jobs_docker_images(names, *args)
  capistrano_nomad_build_jobs_docker_images(names, *args)
  capistrano_nomad_push_jobs_docker_images(names, *args)
end

def capistrano_nomad_upload_jobs(names, *args)
  # Var files can be shared between jobs so don't upload duplicates
  uniq_var_files = names.map { |n| capistrano_nomad_fetch_job_var_files(n, *args) }.flatten.uniq

  uniq_var_files.each do |var_file|
    capistrano_nomad_upload_file(
      local_path: capistrano_nomad_build_local_var_file_path(var_file, *args),
      remote_path: capistrano_nomad_build_release_var_file_path(var_file, *args),
    )
  end

  run_locally do
    names.each do |name|
      nomad_job_options = capistrano_nomad_fetch_job_options(name, *args)

      # Can set job-specific ERB vars
      erb_vars = nomad_job_options[:erb_vars] || {}

      # Can set a custom template instead
      file_basename = nomad_job_options[:template] || name

      capistrano_nomad_upload_file(
        local_path: capistrano_nomad_build_local_job_path(file_basename, *args),
        remote_path: capistrano_nomad_build_release_job_path(name, *args),
        erb_vars: erb_vars,
      )
    end
  end
end

def capistrano_nomad_plan_jobs(names, *args)
  names.each do |name|
    args = [capistrano_nomad_build_release_job_path(name, *args)]

    capistrano_nomad_execute_nomad_command(:plan, *args)
  end
end

def capistrano_nomad_run_jobs(names, namespace: nil)
  names.each do |name|
    run_options = {
      namespace: namespace,
      detach: true,

      # Don't reset counts since they may have been scaled
      preserve_counts: true,
    }

    capistrano_nomad_fetch_job_var_files(name, namespace: namespace).each do |var_file|
      run_options[:var_file] = capistrano_nomad_build_release_var_file_path(var_file, namespace: namespace)
    end

    capistrano_nomad_execute_nomad_command(
      :run,
      run_options,
      capistrano_nomad_build_release_job_path(name, namespace: namespace),
    )
  end
end

# Remove job and run again
def capistrano_nomad_rerun_jobs(names)
  names.each do |name|
    # Wait for jobs to be purged before running again
    capistrano_nomad_purge_jobs([name], is_detached: false)

    capistrano_nomad_run_jobs([name])
  end
end

def capistrano_nomad_upload_plan_jobs(names, *args)
  capistrano_nomad_upload_jobs(names, *args)
  capistrano_nomad_plan_jobs(names, *args)
end

def capistrano_nomad_upload_run_jobs(names, *args)
  capistrano_nomad_upload_jobs(names, *args)
  capistrano_nomad_run_jobs(names, *args)
end

def capistrano_nomad_upload_rerun_jobs(names, *args)
  capistrano_nomad_upload_jobs(names, *args)
  capistrano_nomad_rerun_jobs(names, *args)
end

def capistrano_nomad_deploy_jobs(names, *args)
  capistrano_nomad_assemble_jobs_docker_images(names, *args)
  capistrano_nomad_upload_run_jobs(names, *args)
end

def capistrano_nomad_purge_jobs(names, namespace: nil, is_detached: true)
  names.each do |name|
    capistrano_nomad_execute_nomad_command(:stop, { namespace: namespace, purge: true, detach: is_detached }, name)
  end
end

def capistrano_nomad_display_job_status(name, *args)
  capistrano_nomad_execute_nomad_command(:status, *args, name)
end
