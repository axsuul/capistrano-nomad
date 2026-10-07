# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

class UploadPlanTest < Minitest::Test
  def test_upload_plan_succeeds_for_accepted_plans_and_fails_for_rejected_plans
    Dir.mktmpdir("capistrano-nomad") do |root|
      FileUtils.mkdir_p(["#{root}/config/deploy", "#{root}/nomad/jobs", "#{root}/bin"])
      File.write("#{root}/Capfile", <<~RUBY)
        require "capistrano/setup"
        require "capistrano/deploy"
        require "capistrano/nomad"
        install_plugin Capistrano::Nomad
      RUBY
      File.write("#{root}/config/deploy.rb", <<~RUBY)
        set :application, "plan-test"
        set :deploy_to, #{"#{root}/remote".inspect}
        set :root, #{root.inspect}
        set :current_revision, "test"
        set :nomad_docker_image_types, {}
        SSHKit.config.command_map[:nomad] = #{"#{root}/bin/nomad".inspect}
        nomad_job :example
        set :nomad_token, "force-test-token"
        nomad_namespace :spleencheese do
          nomad_job :"myanonamouse-maintenance"
        end
      RUBY
      File.write("#{root}/config/deploy/test.rb", <<~RUBY)
        server "localhost", roles: [:manager]
        set :sshkit_backend, SSHKit::Backend::Local
      RUBY
      File.write("#{root}/bin/ssh", <<~SH)
        #!/bin/sh
        for argument do command="$argument"; done
        exec /bin/sh -c "$command"
      SH
      FileUtils.chmod(0755, "#{root}/bin/ssh")
      File.write("#{root}/bin/nomad", <<~SH)
        #!/bin/sh
        if [ "$1" = job ]; then
          [ "$NOMAD_TOKEN" = force-test-token ] || exit 98
          printf '%s\n' "$*" >> #{root}/commands
          if [ "$2" = inspect ]; then
            printf '%s\n' "$NOMAD_TEST_JOB"
            exit "${NOMAD_TEST_INSPECT_EXIT:-0}"
          fi
          [ "$2 $3" = 'periodic force' ] || exit 99
          if [ "$NOMAD_TEST_EXIT" = 0 ]; then
            echo 'Created periodic child'
          else
            echo 'Periodic force rejected' >&2
          fi
          exit "$NOMAD_TEST_EXIT"
        fi
        [ "$1" = plan ] || exit 99
        cat "$2"
        case "$NOMAD_TEST_EXIT" in
          0|1) echo 'Scheduler dry-run: accepted';;
          *) echo 'Error determining plan results' >&2;;
        esac
        exit "$NOMAD_TEST_EXIT"
      SH
      FileUtils.chmod(0755, "#{root}/bin/nomad")

      [0, 1, 255, 2].each do |exit_code|
        job = exit_code < 2 ? 'job "example" {}' : 'job "example" {'
        File.write("#{root}/nomad/jobs/example.hcl", job)
        output, status = Open3.capture2e(
          { "NOMAD_TEST_EXIT" => exit_code.to_s, "PATH" => "#{root}/bin:#{ENV.fetch("PATH")}" },
          "bundle", "exec", "cap", "test", "nomad:example:upload_plan",
          chdir: root,
        )

        assert_includes(output, job, output)
        if exit_code < 2
          assert(status.success?, output)
          assert_includes(output, "Scheduler dry-run: accepted")
        else
          refute(status.success?, output)
          assert_includes(output, "Error determining plan results")
        end
      end

      [0, 1, 2].each do |exit_code|
        File.write("#{root}/commands", "")
        output, status = Open3.capture2e(
          { "NOMAD_TEST_EXIT" => exit_code.to_s, "NOMAD_TEST_JOB" => '{"Periodic":{"Enabled":true}}' },
          "bundle", "exec", "cap", "test", "nomad:spleencheese:myanonamouse-maintenance:force",
          chdir: root,
        )

        assert_equal("job inspect -namespace=spleencheese myanonamouse-maintenance\njob periodic force -namespace=spleencheese myanonamouse-maintenance\n", File.read("#{root}/commands"), output)
        assert_equal(exit_code.zero?, status.success?, output)
        assert_includes(output, exit_code.zero? ? "Created periodic child" : "Periodic force rejected")
      end

      ['{"Periodic":null}', '{"Periodic":{"Enabled":false}}'].each do |job|
        File.write("#{root}/commands", "")
        output, status = Open3.capture2e(
          { "NOMAD_TEST_JOB" => job },
          "bundle", "exec", "cap", "test", "nomad:example:force",
          chdir: root,
        )

        refute(status.success?, output)
        assert_includes(output, "Job default/example is not an enabled periodic job")
        assert_equal("job inspect -namespace=default example\n", File.read("#{root}/commands"), output)
      end

      File.write("#{root}/commands", "")
      output, status = Open3.capture2e(
        { "NOMAD_TEST_JOB" => '{"Periodic":{"Enabled":true}}', "NOMAD_TEST_INSPECT_EXIT" => "1" },
        "bundle", "exec", "cap", "test", "nomad:example:force",
        chdir: root,
      )

      refute(status.success?, output)
      assert_equal("job inspect -namespace=default example\n", File.read("#{root}/commands"), output)

      File.write("#{root}/commands", "")
      output, status = Open3.capture2e(
        { "NOMAD_TEST_JOB" => '{"Periodic":{"Enabled":true}}', "NOMAD_TEST_EXIT" => "0" },
        "bundle", "exec", "cap", "test", "nomad:example:force",
        chdir: root,
      )

      assert(status.success?, output)
      assert_equal("job inspect -namespace=default example\njob periodic force -namespace=default example\n", File.read("#{root}/commands"), output)

      if ENV["NOMAD_REAL_BINARY"]
        FileUtils.cp(ENV.fetch("NOMAD_REAL_BINARY"), "#{root}/bin/nomad")
        output, status = Open3.capture2e("bundle", "exec", "cap", "test", "nomad:example:upload_plan", chdir: root)

        refute(status.success?, output)
        assert_includes(output, "Error parsing job file")
      end
    end
  end
end
