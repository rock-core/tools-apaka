module Autoproj
    module Packaging
        class Jenkins
            def self.list_all_jobs
                jobs_file = "/tmp/jenkins-jobs"
                # java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ list-jobs > #{jobs_file}"
                if !system(cmd)
                    raise RuntimeError, "Failed to list all jobs using: #{cmd}"
                end

                all_jobs = []
                File.open(jobs_file,"r") do |file|
                    all_jobs = file.read.split("\n")
                end
                all_jobs
            end

            def self.cleanup_all_jobs
                all_jobs = list_all_jobs
                max_count = all_jobs.size
                i = 1
                all_jobs.each do |job|
                    Packager.info "Cleanup job #{i}/#{max_count}"
                    cleanup_job job
                    i += 1
                end
            end

            def self.remove_all_jobs
                all_jobs = list_all_jobs.delete_if{|job| job.start_with? 'a_' or job.start_with? '0_'}
                max_count = all_jobs.size
                i = 1
                all_jobs.each do |job|
                    Packager.info "Remove job #{i}/#{max_count}"
                    remove_job job
                    i += 1
                end
            end

            def self.who_am_i
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ who-am-i"
                if !system(cmd)
                    raise RuntimeError, "Failed to identify user: please register your public key in jenkins"
                end
            end

            def self.create_cleanup_jobs(force = true)
                binding.pry
                Dir.glob("#{TEMPLATES}/../0_cleanup*").each do |file|
                    name = File.basename(file).gsub(".xml","")
                    if force
                        cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job '#{name}' < #{file}"
                    else
                        cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{name}' < #{file}"
                    end
                    Packager.info "creating cleanup job #{name}"
                    if !system(cmd)
                        Packager.warn "creation of cleanup job #{name} from #{file} failed"
                    end
                end
            end

            # Cleanup job of a given name
            def self.cleanup_job(job_name)
                # java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help delete-builds
                # java -jar jenkins-cli.jar delete-builds JOB RANGE
                # Delete build records of a specified job, possibly in a bulk.
                #   JOB   : Name of the job to build
                #   RANGE : Range of the build records to delete. 'N-M', 'N,M', or 'N'
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ delete-builds '#{job_name}' '1-10000'"
                Packager.info "job '#{job_name}': cleanup with #{cmd}"
                if !system(cmd)
                    Packager.warn "job '#{job_name}': cleanup failed"
                end
            end

            # Remove job of a given name
            def self.remove_job(job_name)
                #java -jar /home/rimresadmin/jenkins-cli.jar -s http://localhost:8080 help delete-job
                #java -jar jenkins-cli.jar delete-job VAL ...
                #    Deletes job(s).
                #     VAL : Name of the job(s) to delete
                cmd = "java -jar ~/jenkins-cli.jar -s http://localhost:8080/ delete-job '#{job_name}'"
                Packager.info "job '#{job_name}': remove with #{cmd}"
                if !system(cmd)
                    Packager.warn "job '#{job_name}': remove failed"
                end
            end

            def self.install_job(name, force = false)
                job_name = name.gsub(/\.xml/,'')
                filename = "#{job_name}.xml"
                if force
                    Packager.info "Update job: #{job_name}"
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job '#{job_name}' < #{filename}")
                else
                    Packager.info "Create job: #{job_name}"
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{job_name}' < #{filename}")
                end
            end

            def self.create_control_job(name, force)
                job_name = name.gsub(/\.xml/,'')
                filename = "#{job_name}.xml"
                if force
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job '#{job_name}' < #{TEMPLATES}/../#{filename}")
                else
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{job_name}' < #{TEMPLATES}/../#{filename}")
                end
            end

            def self.create_control_jobs(force)
                templates = Dir.glob "#{TEMPLATES}/../0_*.xml"
                templates.each do |template|
                    template = File.basename template, ".xml"
                    create_control_job template, force
                end
            end
        end
    end
end

