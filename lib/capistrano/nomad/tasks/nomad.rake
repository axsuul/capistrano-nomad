namespace :nomad do
  desc "Show version"
  task :version do
    capistrano_nomad_execute_nomad_command(:version)
  end

  # Define tasks for all jobs
  capistrano_nomad_define_group_tasks(namespace: :all)

  namespace :all do
    desc "Create missing and remove unused namespaces"
    task :modify_namespaces do
      output = capistrano_nomad_capture_nomad_command(:namespace, :list, t: "'{{range .}}{{ .Name }}|{{end}}'")
      current_namespaces = output.split("|").compact.map(&:to_sym)

      # If key is nil then it actually belongs to the default namespace
      desired_namespaces = fetch(:nomad_jobs).keys.map { |n| n.nil? ? :default : n.to_sym }

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
