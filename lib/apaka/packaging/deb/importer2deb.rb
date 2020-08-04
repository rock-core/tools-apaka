require_relative 'package2deb'
module Apaka
    module Packaging
        module Deb
            class Importer2Deb < Package2Deb
                def initialize(options = Hash.new)
                    super(options)
                end

                def package(pkginfo, options)
                    @current_pkg_info = pkginfo

                    Packager.info "Using package_importer for #{pkginfo.name}"
                    options, unknown_options = Kernel.filter_options options,
                        :distribution => nil,
                        :architecture => nil
                    distribution = options[:distribution]

                    Dir.chdir(packaging_dir(pkginfo)) do

                        dir_name = plain_versioned_name(pkginfo)
                        plain_dir_name = plain_versioned_name(pkginfo)
                        FileUtils.rm_rf File.join(pkginfo.srcdir, "debian")
                        FileUtils.rm_rf File.join(pkginfo.srcdir, "build")

                        # Generate a CMakeLists which installs every file
                        cmake = File.new(dir_name + "/CMakeLists.txt", "w+")
                        cmake.puts "cmake_minimum_required(VERSION 2.6)"
                        add_folder_to_cmake "#{Dir.pwd}/#{dir_name}", cmake, pkginfo.name
                        cmake.close

                        # First, generate the source tarball
                        sources_name = plain_versioned_name(pkginfo)
                        tarball = "#{plain_dir_name}.orig.tar.gz"

                        # Check first if actual source contains newer information than existing
                        # orig.tar.gz -- only then we create a new debian package
                        package_with_update = false
                        if package_updated?(pkginfo)

                            Packager.warn "Package: #{pkginfo.name} requires update #{pkginfo.srcdir}"

                            source_package_dir = File.basename(pkginfo.srcdir)
                            if !tar_gzip(source_package_dir, tarball, pkginfo.latest_commit_time)
                                raise RuntimeError, "Package: failed to tar directory #{source_package_dir}"
                            end
                            package_with_update = true
                        end

                        dsc_files = reprepro.registered_files(versioned_name(pkginfo, distribution),
                                                  rock_release_name,
                                                  "*#{target_platform.distribution_release_name}.dsc")

                        if package_with_update || dsc_files.empty?
                            update_debian_dir(pkginfo, options)
                        else
                            Packager.info "Package: #{pkginfo.name} is up to date"
                        end
                        FileUtils.rm_rf( File.basename(pkginfo.srcdir) )
                    end
                end

                # For importer-packages we need to add every file in the deb-package, for that we "install" every file with CMake
                # This method adds an install-line of every file (including subdirectories) of a file into the given cmake-file
                def add_folder_to_cmake(base_dir, cmake, destination, folder = ".")
                    Dir.foreach("#{base_dir}/#{folder}") do |file|
                        next if file.to_s == "." or file.to_s == ".." or file.to_s.start_with? "."
                        if File.directory? "#{base_dir}/#{folder}/#{file}"
                            # create the potentially empty folder. If the folder is not empty this is useless, but empty folders would not be generated
                            cmake.puts "install(DIRECTORY #{folder}/#{file} DESTINATION share/rock/#{destination}/#{folder} FILES_MATCHING PATTERN .* EXCLUDE)"
                            add_folder_to_cmake base_dir, cmake, destination, "#{folder}/#{file}"
                        else
                            cmake.puts "install(FILES #{folder}/#{file} DESTINATION share/rock/#{destination}/#{folder})"
                        end
                    end
                end


            end
        end
    end
end
