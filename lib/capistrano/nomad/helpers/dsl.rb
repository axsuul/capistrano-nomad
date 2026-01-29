require "active_support/core_ext/hash"

def nomad_docker_image_type(image_type, attributes = {})
  docker_image_types = fetch(:nomad_docker_image_types) || {}
  docker_image_types[image_type] = attributes.reverse_merge(
    # By default build and push Docker image locally
    strategy: :local_push,
  )

  raise ArgumentError, "passing in alias_digest is not allowed!" if attributes[:alias_digest]

  # If Docker image doesn't get pushed, this will still be populated
  docker_image_types[image_type][:alias_digest] = attributes[:alias]

  set(:nomad_docker_image_types, docker_image_types)
end

def nomad_namespace(namespace, **options, &block)
  raise ArgumentError, "cannot define default nomad namespace" if namespace == :default

  nomad_namespaces = fetch(:nomad_namespaces) || {}
  nomad_namespaces[namespace] = options
  set(:nomad_namespaces, nomad_namespaces)

  # Make namespace active for block
  @nomad_namespace = namespace

  instance_eval(&block)

  @nomad_namespace = nil

  # Define tasks for namespace jobs
  namespace(:nomad) do
    capistrano_nomad_define_group_tasks(namespace: namespace)
  end

  true
end

def nomad_job(name, attributes = {})
  # This is the namespace when there's no namespace defined in Nomad too
  @nomad_namespace ||= :default

  attributes[:tags] ||= []

  if (nomad_namespace_options = capistrano_nomad_fetch_namespace_options(namespace: @nomad_namespace))
    # Tags added to namespace should be added to all jobs within
    attributes[:tags] += nomad_namespace_options[:tags] || []

    # ERB vars added to namespace should be added to all jobs within
    if (namespace_erb_vars = nomad_namespace_options[:erb_vars])
      attributes[:erb_vars] ||= {}
      attributes[:erb_vars].reverse_merge!(namespace_erb_vars)
    end
  end

  nomad_jobs = fetch(:nomad_jobs) || Hash.new { |h, n| h[n] = {} }
  nomad_jobs[@nomad_namespace][name] = attributes

  set(:nomad_jobs, nomad_jobs)

  define_tasks = lambda do |namespace: nil|
    description_name = ""
    description_name << "#{namespace}/" if namespace != :default
    description_name << name.to_s

    namespace(name) do
      desc("Build #{description_name} job Docker images")
      task(:build) do
        capistrano_nomad_build_jobs_docker_images([name], namespace: namespace)
      end

      desc("Push #{description_name} job Docker images")
      task(:push) do
        capistrano_nomad_push_jobs_docker_images([name], namespace: namespace)
      end

      desc("Build and push #{description_name} job Docker images")
      task(:assemble) do
        capistrano_nomad_build_jobs_docker_images([name], namespace: namespace)
        capistrano_nomad_push_jobs_docker_images([name], namespace: namespace)
      end

      desc("Upload #{description_name} job and related files")
      task(:upload) do
        capistrano_nomad_upload_jobs([name], namespace: namespace)
      end

      desc("Run #{description_name} job")
      task(:run) do
        capistrano_nomad_run_jobs([name], namespace: namespace, is_detached: capistrano_nomad_job_detached_overridden?)
      end

      desc("Purge and run #{description_name} job again")
      task(:rerun) do
        capistrano_nomad_rerun_jobs([name], namespace: namespace, is_detached: capistrano_nomad_job_detached_overridden?)
      end

      desc("Upload and plan #{description_name} job")
      task(:upload_plan) do
        capistrano_nomad_upload_plan_jobs([name], namespace: namespace)
      end

      desc("Upload and run #{description_name} job")
      task(:upload_run) do
        capistrano_nomad_upload_run_jobs([name], namespace: namespace, is_detached: capistrano_nomad_job_detached_overridden?)
      end

      desc("Upload and re-run #{description_name} job")
      task(:upload_rerun) do
        capistrano_nomad_upload_rerun_jobs([name], namespace: namespace, is_detached: capistrano_nomad_job_detached_overridden?)
      end

      desc("Deploy #{description_name} job")
      task(:deploy) do
        capistrano_nomad_deploy_jobs([name], namespace: namespace, is_detached: capistrano_nomad_job_detached_overridden?)
      end

      desc("Start #{description_name} job")
      task(:start) do
        capistrano_nomad_start_jobs([name], namespace: namespace)
      end

      desc("Stop #{description_name} job")
      task(:stop) do
        capistrano_nomad_stop_jobs([name], namespace: namespace)
      end

      desc("Restart #{description_name} job")
      task(:restart) do
        capistrano_nomad_restart_jobs([name], namespace: namespace)
      end

      desc("Revert #{description_name} job. Specify version with VERSION. Specify targeting tasks with docker image with DOCKER_IMAGE. If none specified, it will revert to previous version")
      task(:revert) do
        capistrano_nomad_revert_jobs([name],
          namespace: namespace,
          version: ENV["VERSION"],
          docker_image: ENV["DOCKER_IMAGE"],
        )
      end

      desc("Purge #{description_name} job")
      task(:purge) do
        capistrano_nomad_purge_jobs([name], namespace: namespace, is_detached: capistrano_nomad_job_detached_overridden?)
      end

      desc("Display status of #{description_name} job")
      task(:status) do
        capistrano_nomad_display_job_status(name, namespace: namespace)
      end

      desc("Open console to #{description_name} job. Specify task with TASK, command with CMD")
      task(:console) do
        job_options = capistrano_nomad_fetch_job_options(name, namespace: namespace)
        command = ENV["COMMAND"].presence || ENV["CMD"].presence || job_options[:console_command] || "/bin/sh"

        capistrano_nomad_exec_within_job(name, command, namespace: namespace, task: ENV["TASK"])
      end

      desc("Display stdout and stderr of #{description_name} job. Specify task with TASK")
      task(:logs) do
        capistrano_nomad_tail_job_logs(name, namespace: namespace, stdout: true)
        capistrano_nomad_tail_job_logs(name, namespace: namespace, stderr: true)
      end

      desc("Display stdout of #{description_name} job. Specify task with TASK")
      task(:stdout) do
        capistrano_nomad_tail_job_logs(name, namespace: namespace, stdout: true)
      end

      desc("Display stderr of #{description_name} job. Specify task with TASK")
      task(:stderr) do
        capistrano_nomad_tail_job_logs(name, namespace: namespace, stderr: true)
      end

      desc("Follow logs of #{description_name} job. Specify task with TASK")
      task(:follow) do
        capistrano_nomad_display_job_logs(name, namespace: namespace, f: true)
      end

      desc("Open job in web UI")
      task(:ui) do
        capistrano_nomad_open_job_ui(name, namespace: namespace)
      end
    end
  end

  namespace(:nomad) do
    if @nomad_namespace
      # Also define tasks without namespace for default Nomad namespace
      define_tasks.call(namespace: @nomad_namespace) if @nomad_namespace == :default

      namespace(@nomad_namespace) do
        define_tasks.call(namespace: @nomad_namespace)
      end
    else
      define_tasks.call
    end
  end
end

def nomad_template_helpers(&block)
  CapistranoNomadErbNamespace.class_eval(&block)
end
