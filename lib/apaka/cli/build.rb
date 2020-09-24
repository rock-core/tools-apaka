require_relative 'base'
require_relative 'package'

module Apaka
    module CLI
        class Build < Base
            def initialize
                super()
            end

            def validate_options(args, options)
                Base.activate_configuration(options)

                args, options = Base.validate_options(args, options)
                [:dest_dir, :base_dir, :patch_dir, :config_file, :log_dir].each do |path_option|
                    Base.validate_path(options, path_option)
                end

                options[:architecture] = validate_architecture(options)
                options[:distribution] = validate_distribution(options)
                options[:release_name] ||= Packaging.default_release_name

                if !options[:log_dir]
                    packager = Apaka::Packaging::Deb::Package2Deb.new(options)
                    options[:log_dir] = packager.log_dir
                end

                return args, options
            end


            def build(packager, debian_pkg_name, orig_options)
                options = orig_options.dup

                debian_package_dir = packager.packaging_dir(debian_pkg_name)

                dsc_file = Dir.glob(File.join(debian_package_dir,"*.dsc")).first
                rebuild_log = File.join(packager.log_dir, "#{debian_pkg_name}-apaka-rebuild.log")
                if !dsc_file
                    raise RuntimeError, "Local rebuild of pkg #{debian_pkg_name} failed -- see #{rebuild_log}"
                end

                options[:log_file] = File.join(packager.log_dir, "#{debian_pkg_name}-apaka-build.log")
                options[:dest_dir] ||= debian_package_dir

                if packager.reprepro.has_package?(debian_pkg_name,
                                              options[:release_name],
                                              options[:distribution],
                                              options[:architecture]) && !options[:rebuild]

                    Apaka::Packaging.warn "#{self.class} package #{debian_pkg_name} is already registered in reprepro - use --rebuild to enforce rebuilding"
                    return
                end
                Apaka::Packaging::Installer.build_package_from_dsc(dsc_file,
                                                 options[:distribution],
                                                 options[:architecture],
                                                 options[:release_name],
                                                 options)
                deb_files = Dir.glob(File.join(debian_package_dir,"*.deb"))
                if deb_files.empty?
                    raise RuntimeError, "Building package failed - no *.deb file found in #{debian_package_dir}"
                end

                deb_file = nil
                deb_files.each do |file|
                    if file =~ /-dbgsym_/
                        next
                    else
                        deb_file = file
                        break
                    end
                end
                if !deb_file
                    raise RuntimeError, "Building package failed - only deb file with debug symbols found"
                end

                Autoproj.info "Registering debian package: #{deb_file}"
                packager.reprepro.register_debian_package(deb_file,
                                                options[:release_name],
                                                options[:distribution],
                                                options[:rebuild])
            end

            def install(packager, debian_pkg_name, options)
                if Apaka::Packaging::Installer.installed?(debian_pkg_name)
                    puts "Package: #{debian_pkg_name} is already installed"
                end

                if packager.target_platform == Apaka::Packaging::TargetPlatform.autodetect_target_platform
                    puts "############### install #{debian_pkg_name} #####################"
                    install_log = File.join(packager.log_dir,"#{debian_pkg_name}-apaka-install.log")
                    packager.install(debian_pkg_name)
                #begin
#                    selected_gems.each do |gem_name, gem_version|
#                        is_osdeps = false
#                        native_name, is_osdeps = packager.native_dependency_name(gem_name)
#                        if !is_osdeps
#                            puts "Installing locally: '#{gem_name}'"
#                            debian_name = packager.debian_ruby_name(gem_name, true)
#                            packager.install debian_name, :distributions => o_distributions
#                        else
#                            puts "Package '#{gem_name}' is available as os dependency: #{native_name}"
#                        end
#                    end
#                    selection.each_with_index do |pkg_name, i|
#                        if pkg = package_info_ask.package(pkg_name)
#                            pkg = pkg.autobuild
#                        else
#                            Apaka::Packaging.warn "Package: #{pkg_name} is not a known rock package (but maybe a ruby gem?)"
#                            next
#                        end
#                        pkginfo = package_info_ask.pkginfo_from_pkg(pkg)
#                        debian_name = packager.debian_name(pkginfo)
#
#                        puts "Installing locally: '#{pkg.name}'"
#                        packager.install debian_name, :distributions => o_distributions, :verbose => Autobuild.verbose
#                    end
#                rescue Exception => e
#                    puts "Local install failed: #{e}"
#                    exit 20
#                end

                else
                    puts "Package has been build for #{packager.target_platform}. Not installing package since current platform is #{Apaka::Packaging::TargetPlatform.autodetect_target_platform}"
                end

            end

            def run(args, options)
                package = Apaka::CLI::Package.new
                args, options = package.validate_options(args, options)

                packaging_results = package.run(args, options)

                jobs = {}
                packaging_results.each do |packager, pkgs|
                    pkgs.each do |pkg_name, info|
                        deps = []
                        if !options[:no_deps]
                            deps = info[:build_deps]
                        end

                        jobs[ pkg_name ] = { :packager => packager,
                                             :type => info[:type],
                                             :debian_name => info[:debian_name],
                                             :dependencies => deps
                        }
                    end
                end
                builder(jobs, options)
            end

            # Takes a list of jobs of the following format
            # { package_name => { :packager => #<Apaka::Packaging::Deb::Package2Deb::0x0fa..>,
            #                     :type => :package # one of :gem, :package or :meta_package
            #                     :debian_name => "rock-myrelease-base-types",
            #                     :dependencies => [ "base/cmake", "rice", ... ]
            # }
            def builder(pending_jobs, options)
                running_jobs = {}
                finished_jobs = {}
                failed_jobs = {}
                skipped_jobs = {}

                succeeded_gem_builds = []
                failed_gem_builds = []
                gem_index = 0

                succeeded_pkg_builds = []
                failed_pkg_builds = []
                pkg_index = 0

                succeeded_meta_builds = []
                failed_meta_builds = []
                meta_index = 0

                status = {}

                wait_queue = Queue.new

                #validate sudo credentials while we are still single threaded
                system("sudo","-v") if !options[:dry_run]
                log_file = File.join(options[:log_dir],'apaka-build_results.yml')
                while !pending_jobs.empty? || !running_jobs.empty?
                    #first, remove all jobs depending on failed jobs
                    pending_jobs.delete_if do |k,v|
                        unsatisfiable_dependencies = v[:dependencies].select do |p|
                            failed_jobs[p] || skipped_jobs[p]
                        end
                        if !unsatisfiable_dependencies.empty?
                            Apaka::Packaging.info "Skipping #{k} due to failed dependencies"
                            skipped_jobs[k] = v
                            true
                        else
                            false
                        end
                    end

                    made_progress = false

                    # find a job where all dependencies are in finished_jobs
                    pending_jobs.delete_if do |pkg,job|
                        if running_jobs.length > options[:parallel]
                            false
                        elsif job[:dependencies].reject { |p| finished_jobs[p] }.empty?
                            #found one. run it.
                            if job[:type] == :gem
                                job[:index] = gem_index
                                puts "    gem (#{job[:index]}) #{pkg}"
                                gem_index += 1
                            elsif job[:type] == :package
                                job[:index] = pkg_index
                                puts "    package (#{job[:index]}) #{pkg}"
                                pkg_index += 1
                            elsif job[:type] == :meta
                                job[:index] = meta_index
                                puts "    meta (#{job[:index]}) #{pkg}"
                                meta_index += 1
                            end
                            job[:thread] = Thread.new do
                                begin
                                    if !options[:dry_run]
                                        build(job[:packager], job[:debian_name], options)
                                        install(job[:packager], job[:debian_name], options) if options[:install]
                                    end
                                    job[:success] = true
                                rescue SignalException => e
                                    puts "Package building aborted by user"
                                    puts e.message
                                    puts e.backtrace.join("\n")
                                rescue Exception => e
                                    puts "    package: #{pkg} building failed"
                                    puts e.message
                                    puts e.backtrace.join("\n")
                                    job[:success] = false
                                ensure
                                    wait_queue.push job
                                end
                            end
                            running_jobs[pkg] = job
                            made_progress = true
                            true
                        else
                            false
                        end
                    end

                    if running_jobs.empty? && !pending_jobs.empty?
                        Apaka::Packaging.error "Remaining (pending) packages which unsatisfied dependencies:"
                        pending_jobs.each do |pkg,job|
                            Apaka::Packaging.error "#{pkg}: #{job[:dependencies].join(", ")}"
                        end
                        exit 1
                    end
                    if !made_progress && !running_jobs.empty?
                        #could not add more jobs, so wait for one to finish.
                        # bound the time we are waiting for jobs to complete so we can
                        # refresh the sudo credentials
                        begin
                            Timeout::timeout(180) do
                                # the job returned by .pop will be removed from running_jobs below,
                                # if it is not already.
                                wait_queue.pop
                            end
                        rescue Timeout::Error
                            # we don't really care, we just want to wait until something happens
                            # or needs to be done, then we check what/if something happened and
                            # do the deed.
                        rescue Interrupt
                            # we want to get all our threads stopped in a reasonable way.
                            # but first, clear out pending_jobs
                            Apaka::Packaging.warn "Aborting."
                            Apaka::Packaging.warn "Packages waiting for build to start: #{pending_jobs.keys}"
                            pending_jobs.clear
                            running_jobs.each do |pkg,job|
                                Apaka::Packaging.warn "Killing worker for #{pkg}"
                                job[:thread].raise Interrupt
                                job[:thread].join
                            end
                            running_jobs.clear
                            puts "Exiting."
                            exit 2
                        end
                        system("sudo","-v") if !options[:dry_run]
                    end

                    running_jobs.delete_if do |pkg,job|
                        if !job[:thread].alive?
                            if job[:success]
                                finished_jobs[pkg] = job
                                if job[:type] == :gem
                                    succeeded_gem_builds << [job[:index], pkg, job[:version]]
                                    status['gems'] = { :succeeded => succeeded_gem_builds,
                                                           :failed => failed_gem_builds }
                                elsif job[:type] == :package
                                    succeeded_pkg_builds << [job[:index], pkg]
                                    status['packages'] = { :succeeded => succeeded_pkg_builds,
                                                           :failed => failed_pkg_builds }
                                elsif job[:type] == :meta
                                    succeeded_meta_builds << [job[:index], pkg]
                                    status['meta'] = { :succeeded => succeeded_meta_builds,
                                                       :failed => failed_meta_builds }
                                end
                            else
                                failed_jobs[pkg] = job
                                if job[:type] == :gem
                                    failed_gem_builds << [job[:index], pkg, job[:version]]
                                    status['gems'] = { :succeeded => succeeded_gem_builds,
                                                           :failed => failed_gem_builds }
                                elsif job[:type] == :package
                                    failed_pkg_builds << [job[:index], pkg]
                                    status['packages'] = { :succeeded => succeeded_pkg_builds,
                                                           :failed => failed_pkg_builds }
                                elsif job[:type] == :meta
                                    failed_meta_builds << [job[:index], pkg]
                                    status['meta'] = { :succeeded => succeeded_meta_builds,
                                                       :failed => failed_meta_builds }
                                end
                            end

                            File.write(log_file, status.to_yaml)
                            true
                        else
                            false
                        end
                    end
                end

                puts "Gem building succeeded for: #{succeeded_gem_builds}"
                puts "Pkg building succeeded for: #{succeeded_pkg_builds}"
                puts "Meta building succeeded for: #{succeeded_meta_builds}"
                puts ""
                puts "Gem building failed for: #{failed_gem_builds}"
                puts "Pkg building failed for: #{failed_pkg_builds}"
                puts "Meta building failed for: #{failed_meta_builds}"
                puts "-- results recorded in: #{log_file}"

            end
        end
    end
end
