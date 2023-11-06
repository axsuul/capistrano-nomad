namespace :nomad do
  desc "Show version"
  task :version do
    capistrano_nomad_execute_nomad_command(:version)
  end

  namespace :all do
    desc "Build all job Docker images"
    task :build do
      capistrano_nomad_fetch_jobs_names_by_namespace.each do |namespace, names|
        capistrano_nomad_push_jobs_docker_images(names, namespace: namespace)
      end
    end

    desc "Push all job Docker images"
    task :push do
      capistrano_nomad_fetch_jobs_names_by_namespace.each do |namespace, names|
        capistrano_nomad_push_jobs_docker_images(names, namespace: namespace)
      end
    end

    desc "Build and push all job Docker images"
    task :assemble do
      capistrano_nomad_fetch_jobs_names_by_namespace.each do |namespace, names|
        capistrano_nomad_assemble_jobs_docker_images(names, namespace: namespace)
      end
    end

    desc "Upload and run all jobs"
    task :upload_run do
      capistrano_nomad_fetch_jobs_names_by_namespace.each do |namespace, names|
        capistrano_nomad_upload_run_jobs(names, namespace: namespace)
      end
    end

    desc "Deploy all jobs"
    task :deploy do
      capistrano_nomad_fetch_jobs_names_by_namespace.each do |namespace, names|
        capistrano_nomad_deploy_jobs(names, namespace: namespace)
      end
    end

    desc "Rerun all jobs"
    task :rerun do
      capistrano_nomad_fetch_jobs_names_by_namespace.each do |namespace, names|
        capistrano_nomad_rerun_jobs(names, namespace: namespace)
      end
    end

    desc "Purge all jobs"
    task :purge do
      capistrano_nomad_fetch_jobs_names_by_namespace.each do |namespace, names|
        capistrano_nomad_purge_jobs(names, namespace: namespace)
      end
    end

    desc "Create missing and remove unused namespaces"
    task :replace_namespaces do
      output = capistrano_nomad_capture_nomad_command(:namespace, :list, t: "'{{range .}}{{ .Name }}|{{end}}'")
      current_namespaces = output.split("|").compact.map(&:to_sym)
      desired_namespaces = fetch(:nomad_jobs).keys
      missing_namespaces = desired_namespaces - current_namespaces
      unused_namespaces = current_namespaces - desired_namespaces

      # Remove unused namespaces
      unused_namespaces.each do |namespace|
        capistrano_nomad_execute_nomad_command(:namespace, :delete, namespace)
      end

      # Create missing namespaces
      missing_namespaces.each do |namespace|
        capistrano_nomad_execute_nomad_command(:namespace, :apply, namespace)
      end
    end
  end

  namespace :docker_images do
    desc "Used for adding hooks before or after pushing Docker images"
    task :push
  end

  namespace :system do
    desc "Clean up Nomad"
    task :clean do
      capistrano_nomad_execute_nomad_command(:system, :gc)
      capistrano_nomad_execute_nomad_command(:system, :reconcile, :summaries)
    end
  end
end
