module Apaka
    module Packaging
        module Deb
            class Gem2Deb < Package2Deb
                GEM_FETCH_MAX_RETRY = 10
                DEFAULT_BUILD_DEPENDENCIES = []
                DEFAULT_RUNTIME_DEPENDENCIES = [ "libyaml-libyaml-perl" ]

                def initialize(options = Hash.new)
                    super(options)
                end

                # Convert with package info
                def convert_package(gem_path, pkginfo, options)
                    # Prepare injection of dependencies through options
                    # provide package name to allow consistent patching schema
                    options[:deps] = pkginfo.dependencies
                    options[:local_pkg] = true
                    options[:package_name] = pkginfo.name
                    options[:latest_commit_time] = pkginfo.latest_commit_time
                    options[:recursive_deps] = @dep_manager.recursive_dependencies(pkginfo)
                    options[:origin_information] = pkginfo.origin_information

                    convert_gem(gem_path, options)
                end

                def package_gems(selected_gems, force_update: nil, patch_dir: nil)
                    packages = {}
                    selected_gems.each do |pkg_name, version|
                        logfile = File.join(self.log_dir, "#{debian_ruby_name(pkg_name)}-apaka-package.log")
                        Autoproj.message "Converting ruby gem: '#{pkg_name}' (see #{logfile})", :green
                        # Fails to be detected as normal package
                        # so we assume it is a ruby gem
                        convert_gems([ [pkg_name, version] ], {:force_update => force_update,
                                                               :patch_dir => patch_dir,
                                                               :log_file => logfile })
                        packages[pkg_name] = { :debian_name => debian_ruby_name(pkg_name),
                                               :build_deps => build_dependencies(pkg_name, version),
                                               :type => :gem
                        }
                    end
                    packages
                end

                # Retrieve the right load path for a gem and the corresponding
                # version
                def get_load_path(gem_name, version)
                    gem_load_paths = []
                    begin
                        gem gem_name, "=#{version}"

                        gem_load_paths = $LOAD_PATH.select do |path|
                            path =~ /#{gem_name}/
                        end
                    rescue LoadError => e
                        # package might not be available
                    end
                    gem_load_paths
                end

                ## requires_access_to
                #
                # target_platform
                # debian_ruby_name

                # Convert all gems that are required
                # by package build with the debian packager
                def convert_gems(gems, options = Hash.new)
                    Packager.info "#{self.class} Convert gems: #{gems} with options #{options.reject { |k,v| k==:deps }}"
                    if gems.empty?
                        return
                    end

                    options, unknown_options = Kernel.filter_options options,
                        :force_update => false,
                        :patch_dir => nil,
                        :local_pkg => false,
                        :distribution => target_platform.distribution_release_name,
                        :architecture => target_platform.architecture,
                        :logfile => STDOUT


                    if unknown_options.size > 0
                        Packager.warn "Apaka::Packaging Unknown options provided to convert gems: #{unknown_options}"
                    end

                    # We use gem2deb for the job of converting the gems
                    # However, since we require some gems to be patched we split the process into the
                    # individual step
                    # This allows to add an overlay (patch) to be added to the final directory -- which
                    # requires to be commited via dpkg-source --commit
                    gems.each do |gem_name, version|
                        gem_dir_name = debian_ruby_name(gem_name)

                        packaging_dirname = packaging_dir(gem_dir_name)
                        if options[:force_update]
                            if File.directory?(packaging_dirname)
                                Packager.info "Debian Gem: rebuild requested -- removing #{packaging_dirname}"
                                FileUtils.rm_rf(packaging_dirname)
                            end
                        end

                        # Check with the version that is already registered
                        # in reprepro
                        version = sync_gem_version(gem_name, version)

                        # Assuming if the .gem file has been download we do not need to update
                        gem_globname = "#{packaging_dirname}/#{gem_name}*.gem"
                        dsc_globname = "#{packaging_dirname}/*#{debian_ruby_name(gem_name)}*.dsc"
                        if options[:force_update] or Dir.glob(gem_globname).empty? or Dir.glob(dsc_globname).empty?
                            Packager.debug "Converting gem: '#{gem_name}' to debian source package"
                            if !File.directory?( packaging_dirname )
                                FileUtils.mkdir_p packaging_dirname
                            end

                            Dir.chdir(packaging_dirname) do
                                cached_gem = false
                                if patch_dir = options[:patch_dir]
                                    cached_gem = gem_from_cache(gem_name, version, patch_dir)
                                end
                                if !cached_gem
                                    gem_fetch(gem_name, version: version)
                                end

                            end
                            gem_file_name = Dir.glob(gem_globname).first
                            if !gem_file_name
                                raise ArgumentError, "Could not retrieve a gem '#{gem_name}', version '#{version}' and options '#{options.reject { |k,v| k==:deps }}'"
                            end
                            convert_gem(gem_file_name, options)
                        else
                            Autoproj.message "gem: #{gem_name} up to date (use --rebuild to enforce repackaging)", :green
                        end
                    end
                end


                def update_deps(dependencies, recursive_deps: nil)
                    dependencies.each do |bdep|
                        if bdep =~ /^ruby-(\S+)/
                            pkg_name = $1
                            release_name, is_osdep = @dep_manager.native_dependency_name(pkg_name)
                            Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                            bdep.replace(release_name)
                        end
                        if !recursive_deps.nil?
                            bdep =~ /^(\S+)/
                            t = $1
                            if !recursive_deps.include?(t) && !DEPWHITELIST.include?(t) && t !~ /^\${/
                                Packager.error "Dependency #{t} required by debian/control but not by rock. Check manifest."
                                bdep.clear
                                ## todo: problem here: bdep (or dep above) does not necessarily reference an actual object, or (as is the case with metaruby=>tools/metaruby) reference a similarly named object.
                                ## in addition, metaruby is a metapackage, pulling tools/metaruby
                            end
                        end
                    end
                    dependencies
                end

                # When providing the path to a gem file converts the gem into
                # a debian package (files will be residing in the same folder
                # as the gem)
                #
                # When provided a patch directory with the name of the gem,
                # e.g. hoe, nokogiri, utilrb
                # the corresponding files will be copy into the built package during
                # the gem building process
                #
                # default options
                #        :patch_dir => nil,
                #        :deps => {:rock_pkginfo => [], :osdeps => [], :nonnative => []},
                #        :distribution =>  nil
                #        :architecture => nil
                #        :local_package => false
                #
                def convert_gem(gem_path, options = Hash.new)
                    Packager.info "Convert gem: '#{gem_path}' with options: #{options.reject { |k,v| k==:deps }}"

                    options, unknown_options = Kernel.filter_options options,
                        :patch_dir => nil,
                        :deps => {:rock_pkginfo => [], :osdeps => [], :nonnative => []},
                        :distribution => target_platform.distribution_release_name,
                        :architecture => target_platform.architecture,
                        :local_pkg => false,
                        :package_name => nil,
                        :recursive_deps => nil,
                        :latest_commit_time => nil,
                        :origin_information => [],
                        :logfile => STDOUT

                    pkg_commit_time = options[:latest_commit_time]

                    if !gem_path
                        raise ArgumentError, "Debian.convert_gem: no #{gem_path} given"
                    end

                    distribution = options[:distribution]
                    logfile = options[:logfile]

                    gem_base_name = ""
                    Dir.chdir(File.dirname(gem_path)) do

                        gem_file_name = File.basename(gem_path)
                        versioned_name, gem_base_name, gem_version = gem_versioned_name(gem_file_name)

                        debian_ruby_name = debian_ruby_name(versioned_name)# + '~' + distribution
                        debian_ruby_unversioned_name = debian_ruby_name.gsub(/-[0-9\.]*(\.rc[0-9]+)?$/,"")
                        Packager.info "Debian ruby name: #{debian_ruby_name} -- directory #{Dir.glob("**")}"
                        Packager.info "Debian ruby unversioned name: #{debian_ruby_unversioned_name}"
                        install_dir = rock_install_directory
                        install_dir = File.join(install_dir,debian_ruby_unversioned_name) if not @current_pkg_info
                        debian_install_dir = "debian/#{debian_ruby_unversioned_name}#{install_dir}"

                        ############
                        # Step 1: calling gem2tgz - if orig.tar.gz is not available
                        ############
                        options[:install_dir] = install_dir
                        registered_orig_tar_gz = reprepro.registered_files(debian_ruby_name(gem_base_name) + "_",
                                             rock_release_name,
                                             "*.orig.tar.gz")

                        if registered_orig_tar_gz.empty?
                            gem2tgz(gem_file_name, options)
                        elsif registered_orig_tar_gz.size == 1
                            FileUtils.cp registered_orig_tar_gz.first, "#{versioned_name}.tar.gz"
                        else
                            raise ArgumentError, "#{self.class}.convert_gem: multiple orig.tar.gz file registered - #{registered_orig_tar_gz}"
                        end

                        ############
                        # Step 2: calling dh-make-ruby
                        ############
                        # Create ruby-<name>-<version> folder including debian/ folder
                        # from .tar.gz
                        #`dh-make-ruby --ruby-versions "ruby1.9.1" #{gem_versioned_name}.tar.gz`
                        #
                        # By default generate for all ruby versions
                        # rename to the rock specific format: use option -p
                        cmd = []
                        env_setting = {}

                        # Note that here, we have tray to make sure the right
                        # environment is used for for dh-make-ruby, otherwise
                        # ruby gems that are installed system wide might be
                        # picked up and the wrong version information is
                        # extracted
                        load_path = get_load_path(gem_base_name, gem_version)
                        if load_path && !load_path.empty?
                            env_setting = {}
                            env_setting["RUBYLIB"] = "#{load_path.join(':')}:\$RUBYLIB"
                        end

                        if File.directory?(debian_ruby_name)
                            FileUtils.rm_rf debian_ruby_name
                        end

                        cmd << "dh-make-ruby"
                        cmd << "--ruby-versions" << "all" <<
                            "#{versioned_name}.tar.gz" <<
                            "-p" << "#{debian_ruby_unversioned_name}"
                        Packager.info "calling: #{cmd.join(" ")}"
                        if !system(env_setting, *cmd, :close_others => true)
                             Packager.warn "calling: #{cmd.join(" ")} failed"
                             raise RuntimeError, "Failed to call #{cmd.join(" ")}"
                        end

                        # Check if patching is needed
                        # To allow patching we need to split `gem2deb -S #{gem_name}`
                        # into its substeps
                        #
                        Dir.chdir(debian_ruby_name) do
                            package_name = options[:package_name] || gem_base_name
                            if patch_pkg_dir(package_name, options[:patch_dir],
                                    options: { install_dir: install_dir,
                                               release_name: rock_release_name,
                                               release_dir: rock_release_install_directory(),
                                               package_name: debian_ruby_unversioned_name,
                                               package_dir: rock_install_directory(package_name: debian_ruby_unversioned_name)
                                             }
                                )
                                dpkg_commit_changes("deb_autopackaging_overlay",
                                                    logfile: logfile)
                                # the above may fail when we patched debian/control
                                # this is going to be fixed next
                            end

                            ################
                            # debian/control
                            ################

                            # Injecting dependencies into debian/control
                            # Since we do not differentiate between build and runtime dependencies
                            # at Rock level -- we add them to both
                            #
                            # Enforces to have all dependencies available when building the packages
                            # at the build server
                            #
                            debcontrol = DebianControl.load("debian/control")

                            # Filter ruby versions out -- we assume chroot has installed all
                            # ruby versions
                            all_deps = options[:deps][:osdeps].select do |name|
                                name !~ /^ruby[0-9][0-9.]*/
                            end

                            options[:deps][:rock_pkginfo].each do |pkginfo|
                                depname, is_osdep = @dep_manager.native_dependency_name(pkginfo)
                                all_deps << depname
                            end

                            # Add actual gem dependencies
                            gem_deps = Hash.new
                            nonnative_packages = options[:deps][:nonnative]
                            if !nonnative_packages.empty?
                                gem_deps = GemDependencies::resolve_all(nonnative_packages)
                            elsif !options[:local_pkg]
                                gem_deps =
                                    GemDependencies::resolve_by_name(gem_base_name, version: gem_version)[:deps]
                            end

                            # Check if the plain package name exists in the given distribution
                            # if that is the case use that one -- if not, then use the ruby name
                            # since then is it is either part of the flow job
                            # or an os dependency
                            gem_deps = gem_deps.keys.each do |k|
                                depname, is_osdep = @dep_manager.native_dependency_name(k)
                                all_deps << depname
                            end

                            DEFAULT_BUILD_DEPENDENCIES.each do |d|
                                all_deps << d
                            end

                            deps = all_deps.uniq

                            if options.has_key?(:recursive_deps)
                                recursive_deps = options[:recursive_deps]
                            else
                                recursive_deps = nil
                            end

                            specfiles = Dir.glob("*.gemspec")
                            spec = nil
                            if specfiles.size == 1
                                spec = ::Gem::Specification::load(specfiles.first)
                            elsif specfiles.size > 1
                                Packager.warn "Gem conversion: more than one specfile found #{specfiles} "\
                                    " ignoring specfiles altogether"
                            end

                            # see https://www.debian.org/doc/debian-policy/ch-controlfields.html
                            debcontrol.source["Section"] = "science"
                            debcontrol.source["Priority"] = "optional"
                            debcontrol.source["Maintainer"] = Apaka::Packaging::Config.maintainer
                            debcontrol.source["Uploaders"] = Apaka::Packaging::Config.maintainer
                            debcontrol.source["Homepage"] = spec.homepage || Apaka::Packaging::Config.homepage
                            debcontrol.source["Vcs-Browser"] = ""
                            debcontrol.source["Vcs-Git"] = ""
                            debcontrol.source["Source"] = debian_ruby_unversioned_name

                            # There should be just one
                            debcontrol.packages.each do |pkg|
                                pkg["Package"] = debian_ruby_unversioned_name
                            end

                            # parse and filter dependencies
                            pkg_depends = []
                            debcontrol.packages.each do |pkg|
                                if pkg.has_key?("Depends")
                                    depends = pkg["Depends"].split(/,\s*/).map { |e| e.strip }
                                    depends.each do |dep|
                                        if dep =~ /^ruby-(\S+)/
                                            pkg_name = $1
                                            release_name, is_osdep = @dep_manager.native_dependency_name(pkg_name)
                                            Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                                            dep.replace(release_name)
                                        end
                                        if !recursive_deps.nil?
                                            dep =~ /^(\S+)/
                                            t = $1
                                            if !recursive_deps.include?(t) && !DEPWHITELIST.include?(t) && t !~ /^\${/
                                                Packager.error "Dependency #{t} required by debian/control but not by rock. Check manifest."
                                            end
                                            dep.clear
                                        end
                                    end
                                else
                                    depends = Array.new
                                end
                                depends.concat deps
                                DEFAULT_RUNTIME_DEPENDENCIES.each do |d|
                                    depends << d
                                end
                                depends.delete("")
                                pkg["Depends"] = depends.uniq.join(", ") unless depends.empty?
                                Packager.info "Depends: #{debian_ruby_name}: injecting dependencies: '#{pkg["Depends"]}'"
                            end

                            # parse and filter build dependencies
                            if debcontrol.source.has_key?("Build-Depends")
                                build_depends = debcontrol.source["Build-Depends"].split(/,\s*/).map { |e| e.strip }
                                build_depends = update_deps(build_depends, recursive_deps: recursive_deps)
                            else
                                build_depends = Array.new
                            end

                            # Add dh-autoreconf to build dependency
                            deps << "dh-autoreconf"
                            build_depends.concat(deps)
                            #`sed -i "s#^\\(^Build-Depends: .*\\)#\\1, #{deps.join(", ")},#" debian/control`

                            debcontrol.source["Build-Depends"] = build_depends.uniq.join(", ")
                            debcontrol.save("debian/control")
                            dpkg_commit_changes("deb_extra_dependencies", logfile: logfile)

                            Packager.info "Relaxing version requirement for: debhelper and gem2deb"
                            # Relaxing the required gem2deb version to allow for for multiplatform support
                            #`sed -i "s#^\\(^Build-Depends: .*\\)gem2deb (>= [0-9\.~]\\+)\\(, .*\\)#\\1 gem2deb\\2#g" debian/control`
                            #`sed -i "s#^\\(^Build-Depends: .*\\)debhelper (>= [0-9\.~]\\+)\\(, .*\\)#\\1 debhelper\\2#g" debian/control`
                            build_depends.each do |bdep|
                                bdep.replace("gem2deb") if bdep =~ /gem2deb.+/
                                bdep.replace("debhelper") if bdep =~ /debhelper.+/
                            end
                            debcontrol.source["Build-Depends"] = build_depends.uniq.join(", ")
                            Packager.info "Build-Depends: #{debian_ruby_name}: injecting dependencies: '#{debcontrol.source["Build-Depends"]}'"

                            File.write("debian/control", DebianControl::generate(debcontrol))
                            dpkg_commit_changes("relax_version_requirements")

                            Packager.info "Change to 'any' architecture"
                            #`sed -i "s#Architecture: all#Architecture: any#" debian/control`
                            debcontrol.packages.each do |pkg|
                              pkg["Architecture"] = "any"
                            end
                            File.write("debian/control", DebianControl::generate(debcontrol))
                            dpkg_commit_changes("any-architecture", logfile: logfile)

                            #-- e.g. for overlays use the original name in the control file
                            # which will be overwritten here
                            Packager.info "Adapt original package name if it exists"
                            original_name = debian_ruby_name(gem_base_name, false)
                            release_name = debian_ruby_name(gem_base_name, true)
                            # Avoid replacing parts of the release name, when it is already adapted
                            # rock-master-ruby-facets with ruby-facets
                            system("sed", "-i", "s##{release_name}##{original_name}#g", "debian/*", :close_others => true)
                            # Inject the true name
                            system("sed", "-i", "s##{original_name}##{release_name}#g", "debian/*", :close_others => true)
                            dpkg_commit_changes("adapt_original_package_name", logfile: logfile)

                            ################
                            # postinst and postrm
                            # debian/package.postinst
                            ################
                            ["postinst","postrm"].each do |action|
                                if File.exist?("debian/package.#{action}")
                                    FileUtils.mv "debian/package.#{action}", "debian/#{debian_ruby_unversioned_name}.#{action}"
                                    dpkg_commit_changes("add_#{action}_script", logfile: logfile)
                                end

                                debian_name = debian_ruby_unversioned_name
                                path = File.join(TEMPLATES,action)
                                template = ERB.new(File.read(path), nil, "%<>", path.gsub(/[^w]/, '_'))
                                rendered = template.result(binding)
                                File.open("debian/#{action}", "w") do |io|
                                    io.write(rendered)
                                end
                            end

                            ####################
                            # debian/copyright
                            source_files = []
                            upstream_name = gem_base_name
                            debian_name = versioned_name
                            origin_information = []
                            if spec
                                copyright ||= spec.authors.join(", ")
                                license ||= spec.licenses.join(", ")
                                origin_information << spec.homepage
                            end

                            # We cannot assume that an existing debian/copyright
                            # file is correct, since gem2deb autogenerates one
                            path = File.join(TEMPLATES,"copyright")
                            template = ERB.new(File.read(path), nil, "%<>", path.gsub(/[^w]/, '_'))
                            rendered = template.result(binding)
                            File.open("debian/copyright", "w") do |io|
                                io.write(rendered)
                            end

                            ################
                            # debian/install
                            ################
                            if File.exist?("debian/install")
                                system("sed", "-i", "s#/usr##{rock_install_directory}#g", "debian/install")
                                dpkg_commit_changes("install_to_rock_specific_directory",
                                                   logfile: logfile)
                                # the above may fail when we patched debian/control
                            end

                            ################
                            # debian/rules
                            ################

                            # Injecting environment setup in debian/rules
                            # packages like orocos.rb will require locally installed packages
                            # Append an installation override
                           Packager.debug "Adapting the target installation directory from /usr to #{install_dir}"

                            ############################
                            # dh_ruby.mk
                            #
                            # Adding custom files and
                            # Documentation generation
                            #
                            # by default dh_ruby only installs files it finds in
                            # the source tar (bin/ and lib/), but we can add our
                            # own through dh_ruby.rake or dh_ruby.mk
                            # dh_ruby.rake / dh_ruby.mk called like this:
                            # <cmd> clean                 # clean
                            # <cmd>                       # build
                            # <cmd> install DESTDIR=<dir> # install
                            # This all is described in detail in "man dh_ruby"
                            ##############################
                            dh_ruby_mk = <<-END
debian_install_prefix=#{debian_install_dir}
install_dir=#{install_dir}
rock_doc_install_dir=$(debian_install_prefix)/share/doc/

build:
	-#{Gem.doc_alternatives.join(" || ")}

clean:
#	-rm -rf doc

install:
	mkdir -p $(rock_doc_install_dir)
	$(if $(wildcard doc/*),-cp -r doc/ $(rock_doc_install_dir))
	$(if $(wildcard api/*),-cp -r api/ $(rock_doc_install_dir))

	echo "Preparing installation of apaka-generated env.sh (current dir $PWD)"
	touch $(debian_install_prefix)/env.sh
	echo "Preparing installation of apaka-generated env.yml (current dir $PWD)"
	touch $(debian_install_prefix)/env.yml
END

                            File.write("debian/dh_ruby.mk", dh_ruby_mk)

                            Packager.info "#{debian_ruby_name}: injecting environment variables into debian/rules"
                            Packager.debug "Allow custom rock name and installation path: #{install_dir}"
                            Packager.debug "Enable custom rock name and custom installation path"

                            system("sed", "-i", "1 a debian_install_prefix = #{debian_install_dir}", "debian/rules", :close_others => true)
                            system("sed", "-i", "1 a env_setup += RUBY_CMAKE_INSTALL_PREFIX=#{debian_install_dir}", "debian/rules", :close_others => true)
                            envsh = Regexp.escape(env_setup(install_prefix: install_dir))
                            system("sed", "-i", "1 a #{envsh}", "debian/rules", :close_others => true)
                            ruby_arch_env = ruby_arch_setup(true)
                            system("sed", "-i", "1 a #{ruby_arch_env}", "debian/rules", :close_others => true)
                            system("sed", "-i", "1 a SHELL := /bin/bash", "debian/rules", :close_others => true)

                            system("sed", "-i", "s#\\(dh .*\\)#__SOURCE_ALL__ $(env_setup) \\1#", "debian/rules", :close_others => true)
                            system("sed", "-i", "s#__SOURCE_ALL__#for file in `find \\$(rock_release_install_dir)/*/env.sh ! -empty -type f -name env.sh`; do source \"\\$$file\"; done;#", "debian/rules", :close_others => true)

                            # Ignore all ruby test results when the binary package is build (on the build server)
                            # via:
                            # dpkg-buildpackage -us -uc
                            #
                            # Thus uncommented line of
                            # export DH_RUBY_IGNORE_TESTS=all
                            Packager.debug "Disabling tests including ruby test result evaluation"
                            system("sed", "-i", "s/#\\(export DH_RUBY_IGNORE_TESTS=all\\)/\\1/", "debian/rules", :close_others => true)
                            # Add DEB_BUILD_OPTIONS=nocheck
                            # https://www.debian.org/doc/debian-policy/ch-source.html
                            system("sed", "-i", "1 a export DEB_BUILD_OPTIONS=nocheck", "debian/rules", :close_others => true)
                            dpkg_commit_changes("disable_tests",
                                               logfile: logfile)
                            build_usr_dir = "debian/#{debian_ruby_unversioned_name}/usr"
                            open('debian/rules','a') do |file|
                                file << "\n"
                                file << "\n"
                                file << "\noverride_dh_auto_install:\n"
                                file << "\techo \"Apaka's override_dh_auto_install called\"\n"
                                file << "\tdh_auto_install \n"
                                file << "\tmkdir -p $(debian_install_prefix)\n"
                                file << "\tcp -R #{build_usr_dir}/* $(debian_install_prefix)/\n"
                                file << "\trm -rf #{build_usr_dir}/*\n"
                                file << "\n"

                                file << @env.gen_export_variable
                                file << "\n"

                                # Make sure that env.sh and env.yml are generated AFTER all files
                                # have been installed
                                file << "override_dh_installdocs:\n"
                                file << "\techo \"Apaka's override_dh_installdocs called\"\n"
                                file << env_create_exports()
                                file << "\n"

                            end

                            ["debian","pkgconfig"].each do |subdir|
                                Dir.glob("#{subdir}/*").each do |file|
                                    prepare_patch_file(file, options: { install_dir: install_dir })
                                    dpkg_commit_changes("adapt_rock_install_dir",
                                                       logfile: logfile)
                                end
                            end

                            ###################
                            # debian/changelog
                            #################################
                            # Any change of the version in the changelog file will directly affect the
                            # naming of the *.debian.tar.gz and the *.dsc file
                            #
                            # Subsequently also the debian package will be (re)named according to this
                            # version string.
                            #
                            # When getting an error such as '"ruby-utilrb_3.0.0.rc1-1.dsc" is already registered with different checksums'
                            # then you probably miss the distribution information or it is not correctly injected
                            if distribution
                                # Changelog entry initially, e.g.,
                                # ruby-activesupport (4.2.3-1) UNRELEASED; urgency=medium
                                #
                                # after
                                # ruby-activesupport (4.2.3-1~trusty) UNRELEASED; urgency=medium
                                debian_changelog = DebianChangelog.new("debian/changelog")
                                debian_changelog.version = "#{debian_changelog.version}~#{distribution}"

                                # Make timestamp constant
                                # https://www.debian.org/doc/debian-policy/ch-source.html
                                #
                                date=`date --rfc-2822 --date="00:00:01"`
                                date=date.strip
                                debian_changelog.maintainer_name = Apaka::Packaging::Config.maintainer_name
                                debian_changelog.maintainer_email = Apaka::Packaging::Config.maintainer_email
                                debian_changelog.date = "#{date}"
                                debian_changelog.body = Array.new
                                debian_changelog.body << "Package automatically built using 'apaka'"
                                options[:origin_information].each do |line|
                                    debian_changelog.body << line
                                end
                                debian_changelog.save("debian/changelog")
                            end

                            ########################
                            # debian/compat
                            ########################
                            set_compat_level(DEBHELPER_DEFAULT_COMPAT_LEVEL, "debian/compat")
                        end


                        # Build only a debian source package -- do not compile binary package
                        Packager.info "Building debian source package: #{debian_ruby_name}"
                        result = `dpkg-source -I -b #{debian_ruby_name}`
                        Packager.info "Resulting debian files: #{Dir.glob("**")} in #{Dir.pwd}"
                    end
                end #end def


                # Validate and sync the used gem version
                #
                def sync_gem_version(gem_name, version)
                    existing_gem_version = gem_get_registered_version(gem_name)
                    if existing_gem_version
                        if existing_gem_version != version
                            Packager.warn "Apaka::Packaging::Debian::convert_gem: conversion of '#{gem_name}'" \
                                " with version '#{version}' requested. "\
                                " However, using version '#{existing_gem_version}' which is already"\
                                " part of the release"
                            version = existing_gem_version
                        else
                            Packager.info "Apaka::Packaging::Debian::convert_gem: conversion of '#{gem_name}' " \
                                " with version '#{version}' requested, which matches existing version in the release"
                        end
                    else
                        Packager.info "Apaka::Packaging::Debian::convert_gem: conversion of '#{gem_name}' " \
                                " with version '#{version}' requested, which is the first registration for this gem in the release"
                    end
                    version
                end

                # Retrieve a gem from cache
                def gem_from_cache(gem_name, version, patch_dir)
                    gem_from_cache = false
                    gem_dir = File.join(patch_dir, "gems", gem_name)
                    if File.directory?(gem_dir)
                        gem = Dir.glob("#{gem_dir}/*.gem")
                        if !gem.empty?
                            gem_from_cache = true
                            Packager.info "Selecting gem from cache: #{gem.join('\n')}, searching for version: '#{version}'"
                            selected_gem = nil
                            if version
                                regexp = Regexp.new(version)
                                gem.each do |gem_name|
                                    if regexp.match(gem_name)
                                        selected_gem = gem_name
                                        break
                                    end
                                end
                            else
                                selected_gem = gem.first
                                Packager.info "Using gem from cache: #{selected_gem} since no version requirement is given (available: #{gem})"
                            end
                            if !selected_gem
                                Packager.warn "Gem(s) in cache does not match the expected version: #{version}"
                                raise RuntimeError, "Failed to find gem for '#{gem_name}' with version '#{version}' in cache: #{File.absolute_path(gem_dir)}"
                            end
                            Packager.info "Selected gem from cache: #{selected_gem}"
                            FileUtils.cp selected_gem, "."
                        end
                    end
                    gem_from_cache
                end

                # Fetch a gem
                def gem_fetch(gem_name, version: nil, max_retry: GEM_FETCH_MAX_RETRY)
                    error = true
                    retry_count = 1
                    loop do
                        Packager.warn "[#{retry_count}/#{max_retry}] Retrying gem fetch #{gem_name}" if retry_count > 1
                        if version
                            pid = Process.spawn("gem", "fetch", gem_name, "--version", version, :close_others => true)
                            #output = `gem fetch #{gem_name} --version '#{version}'`
                        else
                            pid = Process.spawn("gem", "fetch", gem_name, :close_others => true)
                            #output = `gem fetch #{gem_name}`
                        end
                        begin
                            Timeout.timeout(60) do
                                Packager.info 'waiting for gem fetch to end'
                                Process.wait(pid)
                                Packager.info 'gem fetch seems successful'
                                error = false
                            end
                        rescue Timeout::Error
                            Packager.warn 'gem fetch not finished in time, killing it'
                            Process.kill('TERM', pid)
                            error = true
                        end
                        retry_count += 1
                        break if not error or retry_count > max_retry
                    end
                    return error
                end

                # Get the versioned name from path
                def gem_versioned_name(gem_file_name)
                    gem_versioned_name = gem_file_name.sub("\.gem","")

                    # Dealing with _ in original file name, since gem2deb
                    # will debianize it
                    gem_base_name = nil
                    gem_version = nil
                    if gem_versioned_name =~ /(.*)(-[0-9]+\.[0-9\.-]*(-[0-9]+)*)/
                        gem_base_name = $1
                        version_suffix = gem_versioned_name.gsub(gem_base_name,"").gsub(/\.gem/,"")
                        gem_version = version_suffix.sub('-','')
                        Packager.info "#{self.class} gem basename: #{gem_base_name}"
                        Packager.info "#{self.class} gem version: #{gem_version}"
                        gem_versioned_name = gem_base_name.gsub("_","-") + version_suffix
                    else
                        raise ArgumentError, "Converting gem: unknown formatting: '#{gem_versioned_name}' -- cannot extract version"
                    end
                    [gem_versioned_name, gem_base_name, gem_version]
                end

                # Create a new tgz file from an existing *.gem
                # with the new name <gem_versioned_name>.tgz
                # @param gem_file_name
                def gem2tgz(gem_file_name, options)
                    gem_versioned_name, gem_base_name, gem_version  = gem_versioned_name(gem_file_name)

                    license = nil
                    copyright = nil
                    if !File.exist?("#{gem_versioned_name}.tar.gz")
                        Packager.info "#{self.class}: Converting gem: #{gem_versioned_name} in #{Dir.pwd}"
                        # Convert .gem to .tar.gz
                        cmd = ["gem2tgz", gem_file_name]
                        if not system(*cmd, :close_others => true)
                            raise RuntimeError, "#{self.class}: Converting gem: '#{gem_file_name}' failed -- gem2tgz failed"
                        else
                            # Unpack and repack the orig.tar.gz to
                            # (1) remove timestamps to create consistent checksums
                            # (2) remove gem2deb residues that should not be there, e.g. checksums.yaml.gz
                            # (3) guarantee consisted gem naming, e.g. ruby-concurrent turn in ruby-concurrent-0.7.2-x64-86-linux,
                            #     but we require ruby-concurrent-0.7.2
                            #
                            Packager.info "Successfully called: 'gem2tgz #{gem_file_name}' --> #{Dir.glob("**")}"
                            # Get the actual result of the conversion and unwrap
                            gem_tar_gz = Dir.glob("*.tar.gz").first
                            system("tar", "xzf", gem_tar_gz, :close_others => true)
                            FileUtils.rm gem_tar_gz

                            # Check if we need to convert the name
                            if gem_tar_gz != "#{gem_versioned_name}.tar.gz"
                                tmp_source_dir = gem_tar_gz.gsub(/.tar.gz/,"")
                                FileUtils.mv tmp_source_dir, gem_versioned_name
                            end
                            Packager.info "Converted: #{Dir.glob("**")}"

                            # Check if patching is needed
                            # To allow patching we need to split `gem2deb -S #{gem_name}`
                            # into its substeps
                            #
                            Dir.chdir(gem_versioned_name) do
                                package_name = options[:package_name] || gem_base_name

                                if options[:patch_dir]
                                    process_apaka_control(File.join(options[:patch_dir], package_name, "apaka.control") )
                                    patch_pkg_dir(package_name, options[:patch_dir],
                                                  whitelist: ["*.gemspec", "Rakefile", "metadata.yml"],
                                                  options: options
                                                 )
                                end
                                # Make sure we extract the original license
                                # and copyright information
                                Dir.glob("*").grep(/^license/i).each do |file|
                                    license = "\n"
                                    license += File.read(file)
                                    license += "\n"
                                end
                                Dir.glob("*").grep(/^copyright/i).each do |file|
                                    copyright = File.read(file)
                                    copyright += "\n"
                                end
                            end

                            # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=725348
                            checksums_file="checksums.yaml.gz"
                            files = Dir.glob("*/#{checksums_file}")
                            if not files.empty?
                                checksums_file = files.first
                            end

                            if File.exist? checksums_file
                                Packager.info "Pre-packaging cleanup: removing #{checksums_file}"
                                FileUtils.rm checksums_file
                            else
                                Packager.info "Pre-packaging cleannup: no #{checksums_file} found"
                            end


                            tgz_date = nil
                            if pkg_commit_time = options[:latest_commit_time]
                                tgz_date = pkg_commit_time
                            else
                                tgz_date = GemDependencies.get_release_date(gem_base_name, version = gem_version)
                                # If we cannot retrieve the information from the
                                # web
                                #
                                # Prefer metadata.yml over gemspec since it gives a more reliable timestamp
                                if not tgz_date
                                    ['*.gemspec', 'metadata.yml'].each do |file|
                                        Dir.chdir(gem_versioned_name) do
                                            files = Dir.glob("#{file}")
                                            if not files.empty?
                                                if files.first =~ /yml/
                                                    spec = YAML.load_file(files.first)
                                                else
                                                    spec = Gem::Specification::load(files.first)
                                                end
                                            else
                                                Packager.info "Gem conversion: file #{file} does not exist"
                                                next
                                            end

                                            if spec
                                                Packager.info "Loaded gemspec: #{spec}"
                                                if spec.date
                                                    if !tgz_date || spec.date < tgz_date
                                                        tgz_date = spec.date
                                                        Packager.info "#{files.first} has associated time: using #{tgz_date} as timestamp"
                                                    end
                                                    Packager.info "#{files.first} has associated time, but too recent, thus staying with #{tgz_date} as timestamp"
                                                else
                                                    Packager.warn "#{files.first} has no associated time: using current time for packaging"
                                                end
                                            else
                                                Packager.warn "#{files.first} is not a spec file"
                                            end
                                        end
                                    end
                                end
                            end

                            if !tgz_date
                                tgz_date = Time.now
                                Packager.warn "Gem conversion: could not extract time for gem: using current time: #{tgz_date}"
                            else
                                Packager.info "Gem conversion: successfully extracted time for gem: using: #{tgz_date}"
                                files = Dir.glob("#{gem_versioned_name}/metadata.yml")
                                if not files.empty?
                                    spec = YAML.load_file(files.first)
                                    spec.date = tgz_date
                                    File.open(files.first, "w") do |file|
                                        Packager.info "Gem conversion: updating metadata.yml timestamp"
                                        file.write spec.to_yaml
                                    end
                                end
                            end

                            # Repackage
                            source_dir = gem_versioned_name
                            if !tar_gzip(source_dir, "#{gem_versioned_name}.tar.gz", tgz_date)
                                raise RuntimeError, "Failed to reformat original #{gem_versioned_name}.tar.gz for gem"
                            end
                            FileUtils.rm_rf source_dir
                            Packager.info "Converted: #{Dir.glob("**")}"
                        end
                    end
                end

                def build_local_gem(gem_name, options)
                    gem_version = nil
                    debian_package_name = rock_ruby_release_prefix + gem_name

                    # Find gem version
                    Find.find(File.join(build_dir,debian_package_name,"/")).each do |file|
                        if FileTest.directory?(file)
                            if File.basename(file)[0] == ?.
                                Find.prune
                            end
                        end
                        if file.end_with? ".gem"
                            gem_version = File.basename(file).sub(gem_name + '-', '').sub('.gem', '')
                            break
                        end
                    end

                    versioned_build_dir = debian_package_name + '-' + gem_version
                    deb_filename = "#{versioned_build_dir}.deb"
                    build_local(gem_name, debian_package_name, versioned_build_dir, deb_filename, options)
                end

                # Compute the registered version of a gem
                # @return nil if no gem is registered or the version information
                def gem_get_registered_version(gem_name)
                    registered_orig_tar_gz = reprepro.registered_files(debian_ruby_name(gem_name) + "_",
                                             rock_release_name,
                                             "*.orig.tar.gz")
                    if registered_orig_tar_gz.empty?
                        Packager.info "Apaka::Packaging::Debian::convert_gems: no existing orig.tar.gz found in reprepro for #{gem_name}"
                        return nil
                    elsif registered_orig_tar_gz.size == 1
                        registered_orig_tar_gz = registered_orig_tar_gz.first

                        Packager.info "Apaka::Packaging::Debian::convert_gem: existing orig.tar.gz found in reprepro for #{gem_name}: #{registered_orig_tar_gz}"
                        if registered_orig_tar_gz =~ /#{rock_ruby_release_prefix()}([^\/]*)_([0-9]+\.[0-9\.-]*(-[0-9]+)*)\.orig.tar.gz/
                            existing_name = $1
                            existing_gem_version = $2
                            return existing_gem_version
                        else
                            raise RuntimeError,
                                "Apaka::Packaging::Debian::convert_gems: could "\
                                "not extract version information from orig.tar.gz"\
                                "'#{registered_orig_tar_gz}'"
                        end
                    else
                        raise RuntimeError, "Apaka::Packaging::Debian::convert_gems: found "\
                            "multiple orig.tar.gz file, cannot uniquely identify version: "\
                            "#{registered_orig_tar_gz}"
                    end
                end

                def build_dependencies(gem_name, version = nil)
                    deps = package_info_ask.all_required_gems({gem_name => [version]})
                    deps = deps[:gem_versions].to_a.select do |gem,versions|
                        pkg_ruby_name = debian_ruby_name(gem, false)
                        pkg_prefixed_name = debian_ruby_name(gem, true)

                        !( rock_release_platform.ancestorContains(gem) ||
                           rock_release_platform.ancestorContains(pkg_ruby_name) ||
                           rock_release_platform.ancestorContains(pkg_prefixed_name))
                    end .map { |p| p[0] }
                    # remove self from list, e.g., in case of rice
                    deps.delete_if {|k,v| k == gem_name }
                    deps
                end
            end # Gem2Deb
        end
    end
end
