require 'erb'
require 'optparse'

module Autoproj
    module Packaging
        class Installer
            extend Logger::Root("Installer", Logger::INFO)

            def self.create_webserver_config(document_root, packages_subfolder,
                                             release_prefix, target_path)

                Installer.info "Creating webserver configuration: document root: #{document_root}"
                    " packages_subfolder: #{packages_subfolder}, "
                    " release_prefix: #{release_prefix}, "
                    " target_path: #{target_path}"

                template_dir = File.expand_path(File.join(File.dirname(__FILE__),"templates","webserver"))
                apache_config_template = File.join(template_dir, "jenkins.conf")

                template = ERB.new(File.read(apache_config_template), nil, "%<>")
                rendered = template.result(binding)

                File.open(target_path, "w") do |io|
                    io.write(rendered)
                end
                Installer.info "Written config file: #{target_path}"
            end

            def self.install_webserver
                if !system("dpkg -l apache2")
                    Installer.info "Installing apache2"
                    `sudo apt-get -y install apache2`
                else
                    Installer.info "Apache2 is already installed"
                end
            end
        end
    end
end
