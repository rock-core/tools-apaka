require_relative 'reprepro/distributions_config'

module Apaka
    module Packaging
        module Reprepro
            class BaseRepo
                attr_reader :base_dir
                attr_reader :log_dir
                attr_accessor :reprepro_lock
                def initialize(base_dir, log_dir)
                    @base_dir = base_dir
                    @log_dir = log_dir
                    @reprepro_lock = Mutex.new
                end

                # Get the reprepro binary and install the rerepo package if not
                # already present
                def reprepro_bin
                    reprepro = `which reprepro`
                    if $?.exitstatus != 0
                        Packager.warn "Autoinstalling 'reprepro' for managing the debian package repository"
                       system("sudo", "apt-get", "install", "reprepro", :close_others => true)
                       reprepro = `which reprepro`
                    end
                    reprepro.strip
                end

                # Initialize or update the reprepro repository
                #
                def init_conf_dir(release_prefix)
                    if !@reprepro_lock.owned?
                        raise ThreadError.new
                    end

                    conf_dir = File.join(@base_dir, release_prefix, "conf")
                    if File.exist? conf_dir
                        Packager.info "Reprepo repository exists: #{conf_dir} - updating"
                    else
                        Packager.info "Initializing reprepo repository in #{conf_dir}"
                        system("sudo", "mkdir", "-p", conf_dir, :close_others => true)

                        user = Etc.getpwuid(Process.uid).name
                        Packager.info "Set owner #{user} for #{@base_dir}"
                        system("sudo", "chown", "-R", user, @base_dir, :close_others => true)
                        system("sudo", "chown", "-R", user, @base_dir + "/", :close_others => true)
                        system("sudo", "chmod", "-R", "755", conf_dir, :close_others => true)
                    end

                    distributions_file = File.join(conf_dir, "distributions")
                    distributions_conf = nil
                    if !File.exist?(distributions_file)
                        distributions_config = Reprepro::DistributionsConfig.new
                        Config.active_distributions.each do |release_name|
                            rc = Reprepro::ReleaseConfig.new
                            rc.codename = release_name
                            rc.architectures = ["amd64","i386","armel","armhf","arm64","source"]
                            rc.sign_with = Config.sign_with
                            rc.components = "main"
                            rc.udeb_components = "main"
                            rc.tracking = "minimal"

                            distributions_config.releases[rc.codename] = rc
                        end
                    else
                        distributions_config = Reprepro::DistributionsConfig.load(distributions_file)
                        Config.active_distributions.each do |release_name|
                            rc = Reprepro::ReleaseConfig.new
                            rc.codename = release_name
                            rc.architectures = ["amd64","i386","armel","armhf","arm64","source"]
                            rc.sign_with = Config.sign_with
                            rc.components = "main"
                            rc.udeb_components = "main"
                            rc.tracking = "minimal"

                            distributions_config.releases[rc.codename] = rc
                        end
                    end
                    distributions_config.save(distributions_file)
                    reprepro_dir = File.join(@base_dir, release_prefix)
                    cmd = [reprepro_bin]
                    cmd << "-V" << "-b" << reprepro_dir << "clearvanished"
                    Packager.info "reprepro: updating conf/distributions and clearing vanished"
                    logfile = File.join(log_dir,"reprepro-init.log")
                    if !system(*cmd, [:out, :err] => logfile, :close_others => true)
                        Packager.info "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                    end
                end

                def init_repository(release_prefix, target_platform)
                    @reprepro_lock.lock
                    begin
                        init_conf_dir(release_prefix)

                        # Check if Packages file exists: /var/www/apaka-releases/local/dists/jessie/main/binary-amd64/Packages
                        # other initialize properly
                        packages_file = File.join(@base_dir,release_prefix,"dists",target_platform.distribution_release_name,"main",
                                                  "binary-#{target_platform.architecture}","Packages")
                        if !File.exist?(packages_file)
                            reprepro_dir = File.join(@base_dir, release_prefix)
                            logfile = File.join(log_dir,"reprepro-init.log")

                            cmd = [reprepro_bin]
                            cmd << "-V" << "-b" << reprepro_dir <<
                                "export" << target_platform.distribution_release_name
                            Packager.info "Initialize distribution #{target_platform.distribution_release_name} : #{cmd.join(" ")} &> #{logfile}"
                            if !system(*cmd, [:out, :err] => logfile, :close_others => true)
                                Packager.info "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                            end
                            cmd = [reprepro_bin]
                            cmd << "-V" << "-b" << reprepro_dir <<
                                "flood" << target_platform.distribution_release_name <<
                                target_platform.architecture
                            logfile = File.join(log_dir,"reprepro-flood.log")
                            Packager.info "Flood #{target_platform.distribution_release_name} and #{target_platform.architecture}"
                            if !system(*cmd, [:out, :err] => logfile, :close_others => true)
                                Packager.info "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                            end
                        else
                            Packager.info "File: #{packages_file} exists"
                        end
                    ensure
                        @reprepro_lock.unlock
                    end
                end

                # Register the debian package for the given package and codename (= distribution)
                # (=distribution)
                # using reprepro
                def register_debian_package(debian_pkg_file, release_name, codename, force = false)
                    begin
                        reprepro_dir = File.join(@base_dir, release_name)

                        debian_package_dir = File.dirname(debian_pkg_file)
                        debfile = File.basename(debian_pkg_file)
                        debian_pkg_name = debfile.split("_").first
                        logfile = File.join(log_dir,"#{debian_pkg_name}-reprepro.log")

                        if force
                            deregister_debian_package(debian_pkg_name, release_name, codename, true)
                        end
                        @reprepro_lock.lock
                        Dir.chdir(debian_package_dir) do
                            if !File.exists?(debfile)
                                raise ArgumentError, "Apaka::Packaging::register_debian_package: could not find '#{debfile}' in directory: '#{debian_package_dir}'"
                            end

                            cmd = [reprepro_bin]
                            cmd << "-V" << "-b" << reprepro_dir <<
                                "includedeb" << codename << debfile

                            Packager.info "Register deb file: #{cmd.join(" ")} &>> #{logfile}"
                            if !system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                                raise RuntimeError, "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                            end

                            if not has_dsc?(debian_pkg_name, release_name, codename, true)
                                dscfile = Dir.glob("*.dsc").first
                                cmd = [reprepro_bin]
                                cmd << "-V" << "-b" << reprepro_dir <<
                                    "includedsc" << codename <<  dscfile
                                Packager.info "Register dsc file: #{cmd.join(" ")} &>> #{logfile}"
                                if !system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                                    raise RuntimeError, "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                                end
                            end
                        end
                    ensure
                        @reprepro_lock.unlock
                    end
                end

                # Register a debian package
                def deregister_debian_package(pkg_name_expression, release_name, codename, exactmatch = false)
                    @reprepro_lock.lock

                    begin
                        reprepro_dir = File.join(@base_dir, release_name)
                        logfile = File.join(log_dir,"deregistration-reprepro-#{release_name}-#{codename}.log")

                        cmd = [reprepro_bin]
                        cmd << "-V" << "-b" << reprepro_dir

                        if exactmatch
                            cmd << "remove" << codename << pkg_name_expression
                        else
                            cmd << "removematched" << codename << pkg_name_expression
                        end
                        IO::write(logfile, "#{cmd}\n", :mode => "a")
                        Packager.info "Remove existing package matching '#{pkg_name_expression}': #{cmd.join(" ")} &>> #{logfile}"
                        if !system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                            Packager.info "Execution of #{cmd.join(" ")} failed -- see #{logfile}"
                        else
                            cmd = [reprepro_bin]
                            cmd << "-V" << "-b" << reprepro_dir
                            cmd << "deleteunreferenced"
                            IO::write(logfile, "#{cmd}\n", :mode => "a")
                            system(*cmd, [:out, :err] => [logfile, "a"], :close_others => true)
                        end
                    ensure
                        @reprepro_lock.unlock
                    end
                end

                # Check if the *.dsc file has already been registered for a
                # particular release and codename(=distribution)
                def has_dsc?(debian_pkg_name, release_name, codename, reuseLock = false)
                    @reprepro_lock.lock unless reuseLock
                    begin
                        reprepro_dir = File.join(@base_dir, release_name)
                        cmd = "#{reprepro_bin} -T dsc -V -b #{reprepro_dir} list #{codename} #{debian_pkg_name}"
                        package_info = `#{cmd}`
                        if !package_info.empty?
                            Packager.info "Reprepro: dsc file for #{debian_pkg_name} available for #{codename}"
                            return true
                        else
                            Packager.info "Reprepro: dsc file for #{debian_pkg_name} not available for #{codename}"
                            return false
                        end
                    ensure
                        @reprepro_lock.unlock unless reuseLock
                    end
                end

                # Check if the given package in available in reprepro for the given
                # architecture
                # @param debian_pkg_name Name of the debian package
                # @release_name name of the package release, e.g., master-18.04
                # @arch name of the architecture
                def has_package?(debian_pkg_name, release_name, codename, arch)
                    @reprepro_lock.lock

                    begin
                        reprepro_dir = File.join(@base_dir, release_name)
                        cmd = "#{reprepro_bin} -A #{arch} -T deb -V -b #{reprepro_dir} list #{codename} #{debian_pkg_name}"
                        package_info = `#{cmd}`
                        if !package_info.empty?
                            Packager.info "Reprepro: #{debian_pkg_name} available for #{codename} #{arch}"
                            return true
                        else
                            Packager.info "Reprepro: #{debian_pkg_name} not available for #{codename} #{arch}"
                            return false
                        end
                    ensure
                        @reprepro_lock.unlock
                    end
                end

                # Retrieve files from reprepro repository
                def registered_files(debian_pkg_name, release_name,
                                             suffix_regexp)
                    reprepro_dir = File.join(@base_dir, release_name)
                    Dir.glob(File.join(reprepro_dir,"pool","main","**","#{debian_pkg_name}#{suffix_regexp}"))
                end
            end
        end
    end
end
