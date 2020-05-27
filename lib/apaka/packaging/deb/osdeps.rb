require_relative '../packager'

module Apaka
    module Packaging
        module Deb
            class Osdeps
                # Update the automatically generated osdeps list for a given
                # package
                def self.update_osdeps_lists(packager, pkginfo, osdeps_files_dir)
                    Packager.info "Update osdeps lists in #{osdeps_files_dir} for #{pkginfo}"
                    if !File.exist?(osdeps_files_dir)
                        Packager.debug "Creating #{osdeps_files_dir}"
                        FileUtils.mkdir_p osdeps_files_dir
                    else
                        Packager.debug "#{osdeps_files_dir} already exists"
                    end

                    Dir.chdir(osdeps_files_dir) do
                        Packaging::Config.active_configurations.each do |release,arch|
                            selected_platform = TargetPlatform.new(release, arch)
                            file = File.absolute_path("#{rock_release_name}-#{arch}.yml")
                            update_osdeps_list(packager, pkginfo, file, selected_platform)
                        end
                    end
                end

                def self.update_osdeps_list(packager, pkginfo, file, selected_platform)
                    Packager.info "Update osdeps list for: #{selected_platform} -- in file #{file}"

                    list = Hash.new
                    if File.exist? file
                        Packager.info("Packagelist #{file} already exists: reloading")
                        list = YAML.load_file(file)
                    end

                    pkg_name = nil
                    dependency_debian_name = nil
                    is_osdep = nil
                    if pkginfo.is_a? String
                        # Handling of ruby and other gems
                        pkg_name = pkginfo
                        release_name, is_osdep = packager.native_dependency_name(pkg_name, selected_platform)
                        Packager.debug "Native dependency of ruby package: '#{pkg_name}' -- #{release_name}, is available as osdep: #{is_osdep}"
                        dependency_debian_name = release_name
                    else
                        pkg_name = pkginfo.name
                        # Handling of rock packages
                        dependency_debian_name = Deb.debian_name(pkginfo)
                    end

                    if !is_osdep
                        if !packager.reprepro_has_package?(dependency_debian_name, rock_release_name,
                                                  selected_platform.distribution_release_name,
                                                  selected_platform.architecture)

                            Packager.warn "Package #{dependency_debian_name} is not available for #{selected_platform} in release #{rock_release_name} -- not added to osdeps file"
                            return
                        end
                    else
                        Packager.info "Package #{dependency_debian_name} will be provided through an osdep for #{selected_platform}"
                    end

                    # Get the operating system label
                    types, labels = Config.linux_distribution_releases[selected_platform.distribution_release_name]
                    types_string = types.join(",")
                    labels_string = labels.join(",")

                    Packager.debug "Existing definition: #{list[pkg_name]}"
                    pkg_definition = list[pkg_name] || Hash.new
                    distributions = pkg_definition[types_string] || Hash.new
                    distributions[labels_string] = dependency_debian_name
                    pkg_definition[types_string] = distributions

                    list[pkg_name] = pkg_definition
                    Packager.debug "New definition: #{list[pkg_name]}"

                    Packager.debug "Updating osdeps file: #{file} with #{pkg_name} -- #{pkg_definition}"
                    File.open(file, 'w') {|f| f.write list.to_yaml }
                end
            end
        end
    end
end
    
