module Autoproj
    module Packaging
        class Jenkins
            attr_reader :debian_packager

            def initialize(debian_packager)
                @debian_packager = debian_packager
            end

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

            def self.create_control_job(name, options)
                options, unknown_options = Kernel.filter_options options,
                    :force => false

                job_name = name.gsub(/\.xml/,'')
                filename = "#{job_name}.xml"
                if options[:force]
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job '#{job_name}' < #{TEMPLATES}/../#{filename}")
                else
                    system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{job_name}' < #{TEMPLATES}/../#{filename}")
                end
            end

            def self.create_control_jobs(force)
                options, unknown_options = Kernel.filter_options options,
                    :force => false

                templates = Dir.glob "#{TEMPLATES}/../0_*.xml"
                templates.each do |template|
                    template = File.basename template, ".xml"
                    create_control_job template, options
                end
            end

            def create_flow_job(name, selection, selected_gems, release_name, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :parallel => false,
                    :force => false,
                    :package_set_order => ['orocos.toolchain','rock.core','rock']

                if !release_name
                    raise ArgumentError, "Jenkins.create_flow_job requires a release_name -- given: #{release_name}"
                else
                    debian_packager.rock_release_name = release_name
                end

                flow = debian_packager.filter_all_required_packages(debian_packager.all_required_packages(selection, selected_gems))
                flow[:packages] = debian_packager.sort_by_package_sets(flow[:packages], options[:package_set_order])
                flow[:gems].each do |name|
                    if !flow[:gem_versions].has_key?(name)
                        flow[:gem_versions][name] = "noversion"
                    end
                end
                # Filter all packages that are already provided by a rock release
                # this one depends on (which is specified in the configuration file
                # using the depends_on option)

                Packager.info "Creating flow of gems: #{flow[:gems]}"
                package_names = flow[:packages].collect { |pkg| pkg.name }
                Packager.info "Creating flow of packages: #{package_names}"
                create_flow_job_xml(name, flow, release_name, options)
                [:extra_gems => all_packages[:extra_gems], :extra_osdeps => all_packages[:extra_osdeps]]
            end

            def create_flow_job_xml(name, flow, flavor, options)
                options, unknown_options = Kernel.filter_options options,
                    :parallel => false,
                    :force => false

                safe_level = nil
                trim_mode = "%<>"

                template = ERB.new(File.read(File.join(File.dirname(__FILE__), "templates", "jenkins-flow-job.xml")), safe_level, trim_mode)
                rendered = template.result(binding)
                Packager.info "Rendering file: #{File.join(Dir.pwd, name)}.xml"
                File.open("#{name}.xml", 'w') do |f|
                      f.write rendered
                end

                Jenkins.install_job(name, options[:force])
            end

            # Create a jenkins job for a rock package (which is not a ruby package)
            def create_package_job(pkg, options = Hash.new)
                with_rock_release_prefix = false

                # just to update the required gem property
                deps = debian_packager.dependencies(pkg)
                extras = [ :extra_gems => deps[:extra_gems], :extra_osdeps => deps[:osdeps]]

                all_deps = debian_packager.filtered_dependencies(pkg, debian_packager.dependencies(pkg))
                Packager.info "Dependencies of #{pkg.name}: rock: #{all_deps[:rock]}, osdeps: #{all_deps[:osdeps]}, nonnative: #{all_deps[:nonnative].to_a}"

                # Prepare upstream dependencies
                deps = all_deps[:rock].join(", ")
                if !deps.empty?
                    deps += ", "
                end

                options, unknown_options = Kernel.filter_options options,
                    :force => false,
                    :type => :package,
                    # Use parameter for job
                    # for destination and build directory
                    :dir_name => debian_packager.debian_name(pkg),
                    # avoid the rock-release prefix for jobs
                    :job_name => debian_packager.debian_name(pkg, with_rock_release_prefix),
                    :package_name => pkg.name,
                    :dependencies => deps

                Packager.info "Create package job: #{options[:job_name]}, options #{options}"
                create_job(options[:job_name], options)

                extras
            end

            # Create a jenkins job for a ruby package
            def create_ruby_job(gem_name, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :force => false,
                    :type => :gem,
                    # for destination and build directory
                    :dir_name => debian_packager.debian_ruby_name(gem_name),
                    :job_name => gem_name,
                    :package_name => gem_name

                Packager.info "Create ruby job: #{gem_name}, options #{options}"
                create_job(options[:job_name], options)
            end


            # Create a jenkins job
            def create_job(package_name, options = Hash.new)
                options, unknown_options = Kernel.filter_options options,
                    :force => false,
                    :type => :package,
                    :architectures => Packaging::Config.architectures.keys,
                    :distributions => Packaging::Config.active_distributions,
                    :job_name => package_name,
                    :package_name => package_name,
                    :dir_name => package_name

                combinations = combination_filter(options[:architectures], options[:distributions], package_name, options[:type] == :gem, options)


                Packager.info "Creating jenkins-debian-glue job for #{package_name} with"
                Packager.info "         options: #{options}"
                Packager.info "         combination filter: #{combinations}"

                safe_level = nil
                trim_mode = "%<>"
                template = ERB.new(File.read(File.join(File.dirname(__FILE__), "templates", "jenkins-debian-glue-job.xml")), safe_level, trim_mode)
                rendered = template.result(binding)
                rendered_filename = File.join("/tmp","#{options[:job_name]}.xml")
                File.open(rendered_filename, 'w') do |f|
                      f.write rendered
                end

                if system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ create-job '#{options[:job_name]}' < #{rendered_filename}")
                    Packager.info "job #{options[:job_name]}': create-job from #{rendered_filename} succeeded"
                else
                    Packager.info "job #{options[:job_name]}': create-job from #{rendered_filename} failed"
                    if options[:force]
                        Packager.info "job #{options[:job_name]}': trying to update job from #{rendered_filename}"
                        if system("java -jar ~/jenkins-cli.jar -s http://localhost:8080/ update-job '#{options[:job_name]}' < #{rendered_filename}")
                            Packager.warn "job #{options[:job_name]}': update-job from #{rendered_filename} succeeded"
                        else
                            Packager.warn "job #{options[:job_name]}': update-job from #{rendered_filename} failed"
                        end
                    end
                end
            end

            # Combination filter generates a filter for each job
            # The filter allows to prevent building of the package, when this
            # package is already part of the release of a distribution release, e.g.,
            # there is no need to repackage the ruby package 'bundler' if it already
            # exists in a specific release of Ubuntu or Debian
            def combination_filter(architectures, distributions, package_name, isGem, options = Hash.new)
                operating_system = Autoproj::OSDependencies.operating_system

                begin
                    Packager.info "Filter combinations of: archs #{architectures} , dists: #{distributions},
                    package: '#{package_name}', isGem: #{isGem}"
                    whitelist = []
                    Packaging::Config.architectures.each do |requested_architecture, allowed_distributions|
                        allowed_distributions.each do |release|
                            if not distributions.include?(release)
                                next
                            end
                            target_platform = TargetPlatform.new(release, requested_architecture)

                            if Autoproj::Packaging::Config.linux_distribution_releases.has_key?(release)
                                Autoproj::OSDependencies.operating_system = Autoproj::Packaging::Config.linux_distribution_releases[ release ]
                            else
                                raise InvalidArgument, "Custom setting of operating system to: #{distribution} is not supported"
                            end

                            resolved_osdeps = nil
                            if options[:package_name] && package_resolver = Autoproj.osdeps.resolve_package(options[:package_name])
                                begin
                                    if package_resolver.first[0].kind_of?(Autoproj::PackageManagers::AptDpkgManager)
                                        resolved_osdeps = package_resolver.first[2]
                                    end
                                rescue Exception => e
                                    Packager.info "package: #{package_name} has no osdeps as replacement"
                                end
                            end

                            if resolved_osdeps && !resolved_osdeps.empty?
                                Packager.info "package: '#{package_name}' is made available through osdeps #{resolved_osdeps} as part of #{release}"
                            elsif  (isGem && target_platform.contains(debian_packager.debian_ruby_name(package_name,false))) ||
                                    target_platform.contains(package_name)
                                Packager.info "package: '#{package_name}' is part of the linux distribution release: '#{release}'"
                            else
                                whitelist << [release, requested_architecture]
                            end
                        end
                    end
                rescue Exception => e
                    raise
                ensure
                    Autoproj::OSDependencies.operating_system = operating_system
                end

                ret = ""
                and_placeholder = " &amp;&amp; "
                architectures.each do |arch|
                    distributions.each do |dist|
                        if !whitelist.include? [dist, arch]
                            ret += "#{and_placeholder} !(distribution == '#{dist}' &amp;&amp; architecture == '#{arch}')"
                        end
                    end
                end

                # Cut the first and_placeholder away
                ret = ret[and_placeholder.size..-1]
            end
        end
    end
end

