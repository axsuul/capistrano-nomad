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
  nomad_namespaces = fetch(:nomad_namespaces) || {}
  nomad_namespaces[namespace] = options
  set(:nomad_namespaces, nomad_namespaces)

  # Make namespace active for block
  @nomad_namespace = namespace

  instance_eval(&block)

  @nomad_namespace = nil

  true
end

def nomad_job(name, attributes = {})
  nomad_jobs = fetch(:nomad_jobs) || Hash.new { |h, n| h[n] = {} }
  nomad_jobs[@nomad_namespace][name] = attributes

  set(:nomad_jobs, nomad_jobs)

  define_tasks = lambda do |namespace: nil|
    description_name = ""
    description_name << "#{namespace}/" if namespace
    description_name << name.to_s

    namespace(name) do
      desc "Build #{description_name} job Docker images"
      task :build do
        capistrano_nomad_build_jobs_docker_images([name], namespace: namespace)
      end

      desc "Push #{description_name} job Docker images"
      task :push do
        capistrano_nomad_push_jobs_docker_images([name], namespace: namespace)
      end

      desc "Build and push #{description_name} job Docker images"
      task :assemble do
        capistrano_nomad_build_jobs_docker_images([name], namespace: namespace)
        capistrano_nomad_push_jobs_docker_images([name], namespace: namespace)
      end

      desc "Upload #{description_name} job and related files"
      task :upload do
        capistrano_nomad_upload_jobs([name], namespace: namespace)
      end

      desc "Run #{description_name} job"
      task :run do
        capistrano_nomad_run_jobs([name], namespace: namespace, is_detached: false)
      end

      desc "Purge and run #{description_name} job again"
      task :rerun do
        capistrano_nomad_rerun_jobs([name], namespace: namespace, is_detached: false)
      end

      desc "Upload and plan #{description_name} job"
      task :upload_plan do
        capistrano_nomad_upload_plan_jobs([name], namespace: namespace)
      end

      desc "Upload and run #{description_name} job"
      task :upload_run do
        capistrano_nomad_upload_run_jobs([name], namespace: namespace, is_detached: false)
      end

      desc "Upload and re-run #{description_name} job"
      task :upload_rerun do
        capistrano_nomad_upload_rerun_jobs([name], namespace: namespace, is_detached: false)
      end

      desc "Deploy #{description_name} job"
      task :deploy do
        capistrano_nomad_deploy_jobs([name], namespace: namespace, is_detached: false)
      end

      desc "Stop #{description_name} job"
      task :stop do
        capistrano_nomad_stop_jobs([name], namespace: namespace)
      end

      desc "Restart #{description_name} job"
      task :restart do
        capistrano_nomad_restart_jobs([name], namespace: namespace)
      end

      desc "Purge #{description_name} job"
      task :purge do
        capistrano_nomad_purge_jobs([name], namespace: namespace, is_detached: false)
      end

      desc "Display status of #{description_name} job"
      task :status do
        capistrano_nomad_display_job_status(name, namespace: namespace)
      end

      desc "Open console to #{description_name} job. Specify task with TASK, command with CMD"
      task :console do
        command = ENV["CMD"].presence || "/bin/bash"

        capistrano_nomad_exec_within_job(name, command, namespace: namespace, task: ENV["TASK"])
      end

      desc "Display stdout and stderr of #{description_name} job. Specify task with TASK"
      task :logs do
        capistrano_nomad_tail_job_logs(name, namespace: namespace, stdout: true)
        capistrano_nomad_tail_job_logs(name, namespace: namespace, stderr: true)
      end

      desc "Display stdout of #{description_name} job. Specify task with TASK"
      task :stdout do
        capistrano_nomad_tail_job_logs(name, namespace: namespace, stdout: true)
      end

      desc "Display stderr of #{description_name} job. Specify task with TASK"
      task :stderr do
        capistrano_nomad_tail_job_logs(name, namespace: namespace, stderr: true)
      end

      desc "Follow logs of #{description_name} job. Specify task with TASK"
      task :follow do
        capistrano_nomad_display_job_logs(name, namespace: namespace, f: true)
      end
    end
  end

  namespace(:nomad) do
    # Define tasks for service
    if @nomad_namespace
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
