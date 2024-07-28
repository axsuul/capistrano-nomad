require "active_support/core_ext/string"
require "sshkit/interactive"

class CapistranoNomadErbNamespace
  def initialize(context:, vars: {})
    @context = context

    vars.each do |key, value|
      instance_variable_set("@#{key}", value)
    end
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

def capistrano_nomad_build_file_path(parent_path, basename, kind: nil, namespace: nil)
  segments = [parent_path]

  if namespace
    case kind

    # Always upload to namespace folder on remote
    when :release
      segments << namespace

    # Otherwise path can be overriden of where files belonging to namespace are stored locally
    else
      namespace_options = capistrano_nomad_fetch_namespace_options(namespace)

      segments << (namespace_options[:path] || namespace)
    end
  end

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

def capistrano_nomad_build_release_job_path(name, **options)
  options[:kind] = :release

  "#{release_path}#{capistrano_nomad_ensure_absolute_path(capistrano_nomad_build_base_job_path(name, **options))}"
end

def capistrano_nomad_build_release_var_file_path(name, **options)
  options[:kind] = :release

  "#{release_path}#{capistrano_nomad_ensure_absolute_path(capistrano_nomad_build_base_var_file_path(name, **options))}"
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
  capistrano_nomad_run_remotely do |host|
    run_interactively(host) do
      capistrano_nomad_run_nomad_command(:execute, *args)
    end
  end
end

def capistrano_nomad_capture_nomad_command(*args)
  output = nil

  capistrano_nomad_run_remotely do
    output = capistrano_nomad_run_nomad_command(:capture, *args)
  end

  output
end

def capistrano_nomad_find_job_task_details(name, namespace: nil, task: nil)
  task = task.presence || name

  # Find alloc id that contains task
  allocs_output = capistrano_nomad_capture_nomad_command(
    :job,
    :allocs,
    { namespace: namespace, t: "'{{range .}}{{ .ID }},{{ .TaskGroup }}|{{end}}'" },
    name,
  )
  alloc_id = allocs_output.split("|").map { |s| s.split(",") }.find { |_, t| t == task.to_s }&.first

  # Can't continue if we can't choose an alloc id
  return unless alloc_id

  tasks_output = capistrano_nomad_capture_nomad_command(
    :alloc,
    :status,
    { namespace: namespace, t: "'{{range $key, $value := .TaskStates}}{{ $key }},{{ .State }}|{{end}}'" },
    alloc_id,
  )
  tasks_by_score = tasks_output.split("|").each_with_object({}) do |task_output, hash|
    task, state = task_output.split(",")

    score = 0
    score += 5 if state == "running"
    score += 5 unless task.match?(/connect-proxy/)

    hash[task] = score
  end
  task = tasks_by_score.max_by { |_, v| v }.first

  {
    alloc_id: alloc_id,
    name: task,
  }
end

def capistrano_nomad_exec_within_job(name, command, namespace: nil, task: nil)
  capistrano_nomad_run_remotely do
    if (task_details = capistrano_nomad_find_job_task_details(name, namespace: namespace, task: task))
      capistrano_nomad_execute_nomad_command(
        :alloc,
        :exec,
        { namespace: namespace, task: task_details[:name] },
        task_details[:alloc_id],
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

def capistrano_nomad_upload(local_path:, remote_path:, erb_vars: {})
  # If directory upload everything within the directory
  if File.directory?(local_path)
    Dir.glob("#{local_path}/*").each do |path|
      capistrano_nomad_upload(local_path: path, remote_path: "#{remote_path}/#{File.basename(path)}")
    end

  # If file, attempt to always parse it as ERB
  else
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
    final_erb_vars.merge!(fetch(:nomad_template_vars) || {})

    # Add job-specific ERB vars
    final_erb_vars.merge!(erb_vars)

    # We use a custom namespace class so that we can include helper methods into the namespace to make them available
    # for template to access
    namespace = CapistranoNomadErbNamespace.new(
      context: self,
      vars: final_erb_vars,
    )

    string_io = StringIO.new(erb.result(namespace.instance_eval { binding }))

    capistrano_nomad_run_remotely do
      # Ensure parent directory exists
      execute(:mkdir, "-p", File.dirname(remote_path))

      upload!(string_io, remote_path)
    end
  end
end

def capistrano_nomad_fetch_namespace_options(namespace)
  fetch(:nomad_namespaces)&.dig(namespace)
end

def capistrano_nomad_fetch_job_options(name, *args, namespace: nil)
  fetch(:nomad_jobs).dig(namespace, name.to_sym, *args)
end

def capistrano_nomad_fetch_job_var_files(name, *args)
  capistrano_nomad_fetch_job_options(name, :var_files, *args) || []
end

def capistrano_nomad_fetch_jobs_names_by_namespace(namespace: :all)
  # Can pass tags via command line (e.g. TAG=foo or TAGS=foo,bar)
  tags =
    [ENV["TAG"], ENV["TAGS"]].map do |tag_args|
      next unless tag_args.presence

      tag_args.split(",").map(&:presence).compact.map(&:to_sym)
    end
      .flatten
      .compact

  fetch(:nomad_jobs).each_with_object({}) do |(jobs_namespace, jobs_options), hash|
    next if namespace != :all && namespace != jobs_namespace

    hash[jobs_namespace] = jobs_options.each_with_object([]) do |(job_name, job_options), collection|
      # Filter jobs by tags if specified
      next if tags.any? && ((job_options[:tags]&.map(&:to_sym) || []) & tags).empty?

      collection << job_name
    end
  end
end

def capistrano_nomad_fetch_jobs_docker_image_types(names, namespace: nil)
  names.map { |n| fetch(:nomad_jobs).dig(namespace, n.to_sym, :docker_image_types) }.flatten.compact.uniq
end

def capistrano_nomad_define_group_tasks(namespace:)
  namespace(namespace) do
    desc "Build #{namespace} job Docker images"
    task :build do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_push_jobs_docker_images(names, namespace: namespace_by)
      end
    end

    desc "Push #{namespace} job Docker images"
    task :push do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_push_jobs_docker_images(names, namespace: namespace_by)
      end
    end

    desc "Build and push #{namespace} job Docker images"
    task :assemble do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_assemble_jobs_docker_images(names, namespace: namespace_by)
      end
    end

    desc "Upload #{namespace} jobs"
    task :upload do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_upload_jobs(names, namespace: namespace_by)
      end
    end

    desc "Run #{namespace} jobs"
    task :run do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_run_jobs(names, namespace: namespace_by)
      end
    end

    desc "Upload and run #{namespace} jobs"
    task :upload_run do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_upload_run_jobs(names, namespace: namespace_by)
      end
    end

    desc "Deploy #{namespace} jobs"
    task :deploy do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_deploy_jobs(names, namespace: namespace_by)
      end
    end

    desc "Rerun #{namespace} jobs"
    task :rerun do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_rerun_jobs(names, namespace: namespace_by)
      end
    end

    desc "Restart #{namespace} jobs"
    task :restart do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_restart_jobs(names, namespace: namespace_by)
      end
    end

    desc "Stop #{namespace} jobs"
    task :stop do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_stop_jobs(names, namespace: namespace_by)
      end
    end

    desc "Purge #{namespace} jobs"
    task :purge do
      capistrano_nomad_fetch_jobs_names_by_namespace(namespace: namespace).each do |namespace_by, names|
        capistrano_nomad_purge_jobs(names, namespace: namespace_by)
      end
    end
  end
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
    capistrano_nomad_upload(
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

      capistrano_nomad_upload(
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

def capistrano_nomad_run_jobs(names, namespace: nil, is_detached: true)
  names.each do |name|
    run_options = {
      namespace: namespace,
      detach: is_detached,

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
def capistrano_nomad_rerun_jobs(names, **options)
  general_options = options.slice!(:is_detached)

  names.each do |name|
    # Wait for jobs to be purged before running again
    capistrano_nomad_purge_jobs([name], **general_options.merge(is_detached: false))

    capistrano_nomad_run_jobs([name], **general_options.merge(options))
  end
end

def capistrano_nomad_upload_plan_jobs(names, **options)
  capistrano_nomad_upload_jobs(names, **options)
  capistrano_nomad_plan_jobs(names, **options)
end

def capistrano_nomad_upload_run_jobs(names, **options)
  general_options = options.slice!(:is_detached)

  capistrano_nomad_upload_jobs(names, **general_options)
  capistrano_nomad_run_jobs(names, **general_options.merge(options))
end

def capistrano_nomad_upload_rerun_jobs(names, **options)
  general_options = options.slice!(:is_detached)

  capistrano_nomad_upload_jobs(names, **general_options)
  capistrano_nomad_rerun_jobs(names, **general_options.merge(options))
end

def capistrano_nomad_deploy_jobs(names, **options)
  general_options = options.slice!(:is_detached)

  capistrano_nomad_assemble_jobs_docker_images(names, **general_options)
  capistrano_nomad_upload_run_jobs(names, **general_options.merge(options))
end

def capistrano_nomad_restart_jobs(names, **options)
  names.each do |name|
    capistrano_nomad_execute_nomad_command(:job, :restart, options, name)
  end
end

def capistrano_nomad_stop_jobs(names, **options)
  names.each do |name|
    capistrano_nomad_execute_nomad_command(:job, :stop, options, name)
  end
end

def capistrano_nomad_purge_jobs(names, namespace: nil, is_detached: true)
  names.each do |name|
    capistrano_nomad_execute_nomad_command(:stop, { namespace: namespace, purge: true, detach: is_detached }, name)
  end
end

def capistrano_nomad_display_job_status(name, **options)
  capistrano_nomad_execute_nomad_command(:status, options, name)
end

def capistrano_nomad_display_job_logs(name, namespace: nil, **options)
  if (task_details = capistrano_nomad_find_job_task_details(name, namespace: namespace, task: ENV["TASK"]))
    capistrano_nomad_execute_nomad_command(
      :alloc,
      :logs,
      options.merge(namespace: namespace, task: task_details[:name]),
      task_details[:alloc_id],
    )
  else
    # If task can't be determined choose a random allocation
    capistrano_nomad_execute_nomad_command(
      :alloc,
      :logs,
      options.merge(namespace: namespace, job: true),
      name,
    )
  end
end

def capistrano_nomad_tail_job_logs(*args, **options)
  capistrano_nomad_display_job_logs(*args, **options.merge(tail: true, n: 50))
end

def capistrano_nomad_open_job_ui(name, namespace: nil)
  run_locally do
    url = "#{fetch(:nomad_ui_url)}/ui/jobs/#{name}"
    url += "@#{namespace}" if namespace

    # Only macOS supported for now
    execute(:open, url)
  end
end
