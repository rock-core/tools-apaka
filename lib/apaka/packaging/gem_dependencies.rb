require 'rubygems/requirement'
require 'set'
require 'open3'
require 'json'
require 'date'
require 'autoproj'
require 'apaka/packaging/packager'

module Apaka
    module Packaging
        class GemDependencies
            # Parse gem dependencies and return the dependencies
            def self.parse_gem_dependencies(gem_name, gem_dependency, runtime_deps_only = true)
                dependencies = Hash.new
                regexp = /(.*)\s\((.*)\)/
                found_gem = false
                current_version = nil
                versioned_gems = Array.new
                gem_dependency.split("\n").each do |line|
                    if match = /Gem #{gem_name}-([0-9].*)/.match(line)
                        # add after completion of the parsing
                        if current_version
                            versioned_gems << {:version => current_version, :deps => dependencies}
                            # Reset dependencies
                            dependencies = Hash.new
                            current_version = nil
                        end
                        current_version = match[1].strip
                        next
                    elsif match = /Gem/.match(line) # other package names
                        # We assume here that the first GEM entry found is related to the
                        # one we want, discarding the others
                        break
                    elsif !current_version
                        # wait till will find the entry line 'Gem mygem-0.1' to continue processing
                        next
                    end

                    mg = regexp.match(line)
                    if mg
                        dep_gem_name = mg[1].strip
                        dep_gem_version = mg[2].strip
                        # Separate runtime dependencies from development dependencies
                        # Typically we are interested only in the runtime dependencies
                        # for the use case here (that why runtime_deps_only is true as default)
                        if runtime_deps_only && /development/.match(dep_gem_version)
                            next
                        end
                        # There can be multiple version requirement for a dependency,
                        # so we store them as an array
                        dependencies[dep_gem_name] = dep_gem_version.gsub(' ','').split(',')
                    end
                end
                # Finalize by adding the last one found (if there has been one)
                if current_version
                    versioned_gems << { :version => current_version, :deps => dependencies }
                end

                return versioned_gems
            end
            # Get the installation status
            #
            def self.installation_status(gem_name, version_requirements = nil, runtime_deps_only: true)
                gem_dependency_cmd = "gem dependency #{gem_name}"
                if version_requirements && !version_requirements.empty?
                    gem_dependency_cmd += " -v\"#{version_requirements.join(',')}\""
                end
                stdcout, stdcerr, status = Open3.capture3(gem_dependency_cmd)
                if !status.success?
                    gem_dependency = nil
                    return false, nil
                else
                    gem_dependency = stdcout
                    # do a quick check to verify we actually found our gem
                    found = false
                    gem_dependency.split("\n").each do |line|
                        if match = /Gem #{gem_name}-([0-9].*)/.match(line)
                            found = true
                            break;
                        end
                    end
                    if !found
                        gem_dependency = nil
                    end
                end
                return true, parse_gem_dependencies(gem_name, gem_dependency, runtime_deps_only: runtime_deps_only)
            end

            def self.install(gem_name, version_requirements)
                if defined?(::Autoproj::PackageManagers::BundlerManager)
                    install_autoproj2(gem_name, version_requirements)
                elsif defined?(::Autoproj::PackageManager::GemManager)
                    install_autoproj1(gem_name, version_requirements)
                else
                    raise RuntimeError("GemDependencies::install: could not identify proper" \
                                       " installation mechanism for gems in autoproj")
                end
            end

            def self.install_autoproj2(gem_name, version_requirements)
                bundler_manager = ::Autoproj::PackageManagers::BundlerManager.new(::Autoproj::workspace)
                if version_requirements.empty?
                    bundler_manager.install([gem_name])
                else
                    if version_requirements.size != 1
                        raise ArgumentError, "#{self} -- cannot handle more than one version constraints for gem '#{gem_name}'"
                    end
                    bundler_manager.install([gem_name+version_requirements.first])
                end
            end

            def self.install_autoproj1(gem_name, version_requirements)
                gem_manager = ::Autoproj::PackageManagers::GemManager.new(Autoproj.workspace)
                if version_requirements.empty?
                    gem_manager.install([[gem_name]])
                else
                    if version_requirements.size != 1
                        raise ArgumentError, "#{self} -- cannot handle more than one version constraints for gem '#{gem_name}'"
                    end
                    gem_manager.install([[gem_name, version_requirements.first]])
                end
            end

            def self.gem_dependencies(gem_name)
                gem_dependency_cmd = "gem dependency #{gem_name}"
                gem_dependency, stdcerr, status = Open3.capture3(gem_dependency_cmd)
                if !status.success?
                    raise RuntimeError, "GemDependencies::resolve_by_name could not find '#{gem_name}', even though we tried to install it"
                end
                return gem_dependency
            end
            # Resolve the dependency of a gem using `gem dependency <gem_name>`
            # This will only work if the local installation is update to date
            # regarding the gems
            # return [:deps => , :version =>  ]
            def self.resolve_by_name(gem_name, version = nil, runtime_deps_only = true)
                if not gem_name.kind_of?(String)
                    raise ArgumentError, "GemDependencies::resolve_by_name expects string, but got #{gem_name.class} '#{gem_name}'"
                end
                version_requirements = Array.new
                if version
                    if version.kind_of?(Set)
                        version_requirements = version.to_a.compact
                    elsif version.kind_of?(String)
                        version_requirements = version.gsub(' ','').split(',')
                    else
                        version_requirements = version
                    end
                end

                installed, gem_dependency = installation_status(gem_name, version_requirements, runtime_deps_only: runtime_deps_only)
                if !installed
                    Apaka::Packaging.warn "Failed to resolve #{gem_name} via 'gem dependency' -- autoinstalling"
                    install(gem_name, version_requirements)
                    installed, gem_dependency = installation_status(gem_name, version_requirements)
                    if !installed
                        raise RuntimeError, "GemDependencies.resolve_by_name: failed to autoinstall gem '#{gem_name}'"
                    end
                end

                versioned_gems = gem_dependency
                # pick last, i.e. highest version
                requirements = Array.new
                version_requirements.each do |requirement|
                    requirements << Gem::Version::Requirement.new(requirement)
                end
                versioned_gems = versioned_gems.select do |description|
                    do_select = true
                    requirements.each do |required_version|
                        available_version = Gem::Version.new(description[:version])
                        if !required_version.satisfied_by?(available_version)
                            do_select = false
                        end
                    end
                    do_select
                end
                if versioned_gems.empty?
                    raise RuntimeError, "GemDependencies::resolve_by_name failed to find a (locally installed) gem '#{gem_name}' that satisfies the version requirements: #{version_requirements}"
                else
                    versioned_gems.last
                end
            end

            # Resolve all dependencies of a list of name or |name,version| tuples of gems
            # Returns[Hash] with keys as required gems and versioned dependencies
            # as values (a Ruby Set)
            def self.resolve_all(gems)
                Apaka::Packaging.info "Resolve all: #{gems}"

                dependencies = Hash.new
                handled_gems = Set.new

                if gems.kind_of?(String)
                    gems = [gems]
                end

                remaining_gems = Hash.new
                if gems.kind_of?(Array)
                    gems.collect do |value|
                        # only the gem name is given
                        if value.kind_of?(String)
                            name = value
                            version = nil
                        else
                            name, version = value
                        end

                        remaining_gems[name] ||= Array.new
                        remaining_gems[name] << version if version
                    end
                elsif gems.kind_of?(Hash)
                    remaining_gems = gems
                end

                Apaka::Packaging.info "Resolve remaining: #{remaining_gems}"

                while !remaining_gems.empty?
                    Apaka::Packaging.info "Resolve all: #{remaining_gems.to_a}"
                    remaining = Hash.new
                    remaining_gems.each do |gem_name, gem_versions|
                        deps = resolve_by_name(gem_name, gem_versions)[:deps]
                        handled_gems << gem_name

                        dependencies[gem_name] = Hash.new
                        deps.each do |gem_dep_name, gem_dep_version|
                            dependencies[gem_name][gem_dep_name] ||= Array.new
                            dependencies[gem_name][gem_dep_name] += gem_dep_version

                            if !handled_gems.include?(gem_dep_name)
                                remaining[gem_dep_name] ||= Array.new
                                remaining[gem_dep_name] += gem_dep_version
                            end
                        end
                    end
                    remaining_gems.select! { |g| !handled_gems.include?(g) }
                    remaining.each do |name, versions|
                        remaining_gems[name] ||= Array.new
                        remaining_gems[name] = (remaining_gems[name] + versions).uniq
                    end
                end
                dependencies
            end

            # Sort gems based on their interdependencies
            # Dependencies is a hash where the key is the gem and
            # the value is the set of versioned dependencies
            def self.sort_by_dependency(dependencies = Hash.new)
                ordered_gem_list = Array.new
                while true
                    if dependencies.empty?
                        break
                    end

                    handled_packages = Array.new

                    # Take all gems which are either standalone, or
                    # whose dependencies have already been processed
                    dependencies.each do |gem_name, gem_dependencies|
                        if gem_dependencies.empty?
                            handled_packages << gem_name
                            ordered_gem_list << gem_name
                        end
                    end

                    # Remove handled packages from the list of dependencies
                    handled_packages.each do |gem_name|
                        dependencies.delete(gem_name)
                    end

                    # Remove the handled packages from the dependency lists
                    # of all other packages
                    dependencies_refreshed = Hash.new
                    dependencies.each do |gem_name, gem_dependencies|
                        gem_dependencies.reject! { |x, version| handled_packages.include? x }
                        dependencies_refreshed[gem_name] = gem_dependencies
                    end
                    dependencies = dependencies_refreshed

                    if handled_packages.empty? && !dependencies.empty?
                        raise ArgumentError, "Unhandled dependencies of gem: #{dependencies}"
                    end
                end
                ordered_gem_list
            end

            # Sorted list of dependencies
            def self.sorted_gem_list(gems)
                dependencies = resolve_all(gems)
                sort_by_dependency(dependencies)
            end

            def self.gem_exact_versions(gems)
                gem_exact_version = Hash.new
                gems.each do |gem_name, version_requirements|
                    gem_exact_version[gem_name] = resolve_by_name(gem_name, version_requirements)[:version]
                end
                gem_exact_version
            end

            # Check is the given name refers to an existing gem
            # uses 'gem fetch' for testing
            def self.is_gem?(gem_name)
                if gem_name =~ /\//
                    Apaka::Packaging.info "GemDependencies: invalid name -- cannot be a gem"
                    return false
                end
                # Check if this is a gem or not
                Dir.chdir("/tmp") do
                    outfile = "/tmp/gem-fetch-#{gem_name}"
                    if not File.exist?(outfile)
                        if !system("gem", "fetch", gem_name, [ :out, :err] => outfile)
                            return false
                        end
                    end
                    if !system("grep", "-i", "ERROR", :in => outfile, [:out, :err] => "/dev/null")
                        Apaka::Packaging.info "GemDependencies: #{gem_name} is a ruby gem"
                        return true
                    end
                end
                return false
            end

            # Get the release date for a particular gem
            # if no version is given, then the latest is used
            #
            # This performs a webquery on rubygems.org
            def self.get_release_date(gem_name, version = nil)
                json_txt, err, status = Open3.capture3("curl https://rubygems.org/api/v1/versions/#{gem_name}.json")
                if status.success?
                    json = JSON.parse(json_txt)
                    json.each do |desc|
                        if not version or desc["number"] == version
                            built_at = desc['built_at']
                            Apaka::Packaging.info "GemDependencies: gem #{gem_name}, version #{version} built at: #{built_at}"
                            if built_at =~ /([0-9]{4}-[0-9]{2}-[0-9]{2})T/
                                return DateTime.strptime($1, "%Y-%m-%d")
                            end
                        end
                    end
                else
                    Apaka::Packaging.info "GemDependencies: gem #{gem_name}, version #{version} could not retrieve release date"
                end
                nil
            end
        end # GemDependencies
    end # Packaging
end # Apaka
