module Apaka
    module Packaging
        module Deb
            class Environment
                attr_reader :packager

                def initialize(packager)
                    @packager = packager
                end

                # Create the environment setup
                # @param install_prefix [String] nil per default, so that is will
                #     resolve to rock_install_directory - gem handling requires however
                #     a custom setting
                #
                def create_setup(install_prefix: nil)
                    Packager.info "Creating envsh"
                    home_env            = "HOME=/home/ "
                    path_env            = "PATH="
                    rubylib_env         = "RUBYLIB="
                    pkgconfig_env       = "PKG_CONFIG_PATH="
                    rock_dir_env        = "Rock_DIR="
                    ld_library_path_env = "LD_LIBRARY_PATH="
                    cmake_prefix_path   = "CMAKE_PREFIX_PATH="
                    orogen_plugin_path  = "OROGEN_PLUGIN_PATH="
                    rock_library_dirs = ""
                    envsh = ""

                    install_prefix = packager.rock_install_directory unless install_prefix

                    packager.rock_release_hierarchy.each do |release_name|
                        install_dir = File.join(packager.rock_base_install_directory, release_name)
                        install_dir_varname = "#{release_name.gsub(/\./,'').gsub(/-/,'')}_install_dir"
                        install_dir_var ="$(#{install_dir_varname})"
                        envsh += "#{install_dir_varname} = #{install_dir}\n"

                        path_env    += "#{File.join(install_dir_var, "bin")}:"

                        # Update execution path for orogen, so that it picks up ruby-facets (since we don't put much effort into standardizing facets it installs in
                        # vendor_ruby/standard and vendory_ruby/core) -- from Ubuntu 13.04 ruby-facets will be properly packaged
                        rubylib_env += "#{File.join(install_dir_var, "$(rockruby_libdir)")}:"
                        rubylib_env += "#{File.join(install_dir_var, "$(rockruby_archdir)")}:"
                        rubylib_env += "#{File.join(install_dir_var, "lib/ruby/vendor_ruby/standard")}:"
                        rubylib_env += "#{File.join(install_dir_var, "lib/ruby/vendor_ruby/core")}:"
                        rubylib_env += "#{File.join(install_dir_var, "lib/ruby/vendor_ruby")}:"

                        pkgconfig_env += "#{File.join(install_dir_var,"lib/pkgconfig")}:"
                        pkgconfig_env += "#{File.join(install_dir_var,"lib/$(arch)/pkgconfig")}:"
                        rock_dir_env += "#{File.join(install_dir_var, "share/rock/cmake")}:"
                        ld_library_path_env += "#{File.join(install_dir_var,"lib")}:#{File.join(install_dir_var,"lib/$(arch)")}:"
                        cmake_prefix_path += "#{install_dir_var}:"
                        orogen_plugin_path += "#{File.join(install_dir_var,"share/orogen/plugins")}:"
                        rock_library_dirs += "#{File.join(install_dir_var,"lib")}:#{File.join(install_dir_var,"lib/$(arch)")}:"
                    end

                    pkgconfig_env       += "/usr/share/pkgconfig:/usr/lib/$(arch)/pkgconfig:"

                    path_env            += "\$$PATH"
                    rubylib_env         += "\$$RUBYLIB"
                    pkgconfig_env       += "\$$PKG_CONFIG_PATH"
                    rock_dir_env        += "\$$Rock_DIR"
                    ld_library_path_env += "\$$LD_LIBRARY_PATH"
                    cmake_prefix_path   += "\$$CMAKE_PREFIX_PATH"
                    orogen_plugin_path  += "\$$OROGEN_PLUGIN_PATH"

                    envsh +=  "env_setup =  #{path_env}\n"
                    envsh += "env_setup += #{home_env}\n"
                    envsh += "env_setup += #{rubylib_env}\n"
                    envsh += "env_setup += #{pkgconfig_env}\n"
                    envsh += "env_setup += #{rock_dir_env}\n"
                    envsh += "env_setup += #{ld_library_path_env}\n"
                    envsh += "env_setup += #{cmake_prefix_path}\n"
                    envsh += "env_setup += #{orogen_plugin_path}\n"

                    typelib_cxx_loader = nil
                    if packager.target_platform.contains("castxml")
                        typelib_cxx_loader = "castxml"
                    elsif packager.target_platform.contains("gccxml")
                        typelib_cxx_loader = "gccxml"
                    else
                        raise ArgumentError, "TargetPlatform: #{packager.target_platform} does neither support castxml nor gccml - cannot build typelib"
                    end
                    if typelib_cxx_loader
                        envsh += "export TYPELIB_CXX_LOADER=#{typelib_cxx_loader}\n"
                    end
                    envsh += "export DEB_CPPFLAGS_APPEND=-std=c++11\n"
                    envsh += "export npm_config_cache=/tmp/npm\n"
                    envsh += "rock_library_dirs=#{rock_library_dirs}\n"
                    envsh += "rock_base_install_dir=#{packager.rock_base_install_directory}\n"
                    envsh += "rock_release_install_dir=#{packager.rock_release_install_directory}\n"
                    envsh += "rock_install_dir=#{install_prefix}\n"
                    envsh
                end

                # Generate an export statement for a makefile, to test the
                # existance of the given dir under the install_prefix and add it to
                # the given variable
                #
                # $(if $(wildcard <install_prefix>/<dirname>/*),-printf
                # \"PATH=$(rock_install_dir)/bin:\\\$${PATH}\\nexport PATH\\n\" >>
                # <install_prefix>/env.sh\n"
                def create_export(varname, dirname, install_prefix: "$(debian_install_prefix)", file_suffix: nil)
                    if dirname and !dirname.empty?
                        test_path = File.join(install_prefix,dirname,"*#{file_suffix}")
                    else
                        test_path = File.join(install_prefix,"*#{file_suffix}")
                    end
                    return "\t$(if $(wildcard #{test_path}),-printf \"#{varname}=$(rock_install_dir)/#{dirname}:\\\$${#{varname}}\\nexport #{varname}\\n\" >> #{install_prefix}/env.sh)\n"
                end

                def create_exports(install_prefix: "$(debian_install_prefix)")
                    exports = ""
                    exports += create_export("PATH","bin", install_prefix: install_prefix)
                    exports += create_export("CMAKE_PREFIX_PATH","", install_prefix: install_prefix)
                    # PKG_CONFIG_PATH
                    exports += create_export("PKG_CONFIG_PATH","lib/pkgconfig", install_prefix: install_prefix, file_suffix: "\.pc")
                    exports += create_export("PKG_CONFIG_PATH","lib/$(arch)/pkgconfig", install_prefix: install_prefix, file_suffix: "\.pc")
                    #RUBYLIB
                    exports += create_export("RUBYLIB","lib/ruby/$(ruby_ver)", install_prefix: install_prefix)
                    exports += create_export("RUBYLIB","lib/$(arch)/ruby/$(ruby_ver)", install_prefix: install_prefix)
                    exports += create_export("RUBYLIB","lib/site_ruby", install_prefix: install_prefix)
                    exports += create_export("RUBYLIB","lib/$(arch)/site_ruby", install_prefix: install_prefix)
                    exports += create_export("RUBYLIB","lib/ruby/vendor_ruby", install_prefix: install_prefix)
                    exports += create_export("RUBYLIB","lib/$(arch)/ruby/vendor_ruby/$(ruby_ver)", install_prefix: install_prefix)
                    #RUBYLIB needed for qt(bindings) which does require #'2.5/qtruby4' for instance
                    exports += create_export("RUBYLIB","lib/ruby/vendor_ruby/standard", install_prefix: install_prefix)
                    exports += create_export("RUBYLIB","lib/ruby/vendor_ruby/core", install_prefix: install_prefix)
                    exports += create_export("RUBYLIB","lib/ruby", install_prefix: install_prefix)
                    exports += create_export("RUBYLIB","lib/$(arch)/ruby", install_prefix: install_prefix)

                    #LD_LIBRARY_PATH
                    exports += create_export("LD_LIBRARY_PATH","lib/$(arch)", install_prefix: install_prefix, file_suffix: "\.so")
                    exports += create_export("LD_LIBRARY_PATH","lib", install_prefix: install_prefix, file_suffix: "\.so")
                    #exports += create_export("LIBRARY_PATH","lib/$(arch)", install_prefix: install_prefix, file_suffix: "\.so")
                    #exports += create_export("LIBRARY_PATH","lib", install_prefix: install_prefix, file_suffix: "\.so")

                    # PYTHON
                    exports += create_export("PYTHONPATH","lib/python$(python_version)/site-packages", install_prefix: install_prefix)
                    exports
                end
            end
        end
    end
end
