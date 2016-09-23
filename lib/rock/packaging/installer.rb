require 'erb'
require 'optparse'

module Autoproj
    module Packaging
        class Installer
            extend Logger::Root("Installer", Logger::INFO)

            BUILDER_DEBS=["dh-autoreconf","cdbs","cmake","apt"]
            WEBSERVER_DEBS=["apache2"]

            def self.create_webserver_config(document_root, packages_subfolder,
                                             release_prefix, target_path)

                Installer.info "Creating webserver configuration: \n" \
                    "    document root: #{document_root}\n" \
                    "    packages_subfolder: #{packages_subfolder}\n" \
                    "    release_prefix: #{release_prefix}\n" \
                    "    target_path: #{target_path}"

                template_dir = File.expand_path(File.join(File.dirname(__FILE__),"templates","webserver"))
                apache_config_template = File.join(template_dir, "jenkins.conf")

                template = ERB.new(File.read(apache_config_template), nil, "%<>")
                rendered = template.result(binding)

                File.open(target_path, "w") do |io|
                    io.write(rendered)
                end
                Installer.debug "Written config file: #{target_path}"
            end

            def self.install_webserver_config(config_path, release_prefix)
                target_config_file = "100_jenkins-#{release_prefix}.conf"
                apache_config = File.join("/etc","apache2","sites-available",target_config_file)
                `sudo cp #{config_path} #{apache_config}`
                if $?.exitstatus == 0
                    `sudo a2ensite #{target_config_file}`
                    if $?.exitstatus == 0
                        `sudo service apache2 reload`
                        Installer.info "Activated apache site #{apache_config}"
                    else
                        Installer.warn "#{cmd} failed -- could not enable apache site #{apache_config}"
                    end
                else
                    Installer.warn "#{cmd} failed -- could not install site #{config_path} as #{apache_config}"
                end
            end

            def self.install_all_requirements
                install_package_list BUILDER_DEBS
                install_package_list WEBSERVER_DEBS
            end

            def self.install_package_list(list = Array.new)
                list.each do |pkg_name|
                    install_package pkg_name
                end
            end

            def self.install_package(package_name)
                if installed?(package_name)
                    Installer.info "Installing '#{package_name}'"
                    `sudo apt-get -y install #{package_name}`
                else
                    Installer.info "'#{package_name}' is already installed"
                end
            end

            def self.installed?(package_name)
                return !system("dpkg -l #{package_name}")
            end
        end
    end
end
