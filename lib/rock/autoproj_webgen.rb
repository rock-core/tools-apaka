module Rock
    module Doc
        def self.render_item(name, value = nil)
            if value
                "<li><b>#{name}</b>: #{value}</li>"
            else
                "<li><b>#{name}</b></li>"
            end
        end

        def self.render_page(path, content)
            if File.file?(path)
                return if File.read(path) == content
            end

            File.open(path, 'w') do |io|
                io.puts content
            end
        end

        def self.name_to_path(name)
            name.gsub(/[^\w]/, '_')
        end

        def self.render_vcs(vcs)
            value = [['type', vcs.type], ['url', vcs.url]].concat(vcs.options.to_a.sort_by { |k, _| k.to_s })
            value = value.map do |key, value|
                if value.respond_to?(:to_str) && File.file?(value)
                    value = Pathname.new(value).relative_path_from(Pathname.new(Autoproj.root_dir))
                elsif value =~ /git:\/\/(.*)\.git/
                    value = "<a href=\"http://#{$1}\">#{value}</a>"
                end
                "<tr><td>#{key}</td><td>#{value}</td></tr>"
            end.join("\n")
            value = "<table>#{value}</table>"
        end

        def self.render_package_set_header(pkg_set)
            result = []
            result << ['name', pkg_set.name]

            if pkg_set.empty?
                result << ['is empty']
                return result.map { |v| render_item(*v) }
            end

            result << ["from", render_vcs(pkg_set.vcs)]

            imports = pkg_set.each_imported_set.to_a
            if !imports.empty?
                imports.each do |imported_set|
                    result << ["imports", Doc.package_set_link(imported_set.name, 1)]
                end
            end


            set_packages = pkg_set.each_package.sort_by(&:name)
            set_packages = set_packages.map do |pkg|
                Doc.package_link(pkg.name, 1)
            end
            result << ['packages', set_packages.join(", ")]
            result << ['osdeps', pkg_set.each_osdep.map(&:first).sort.map { |name| Doc.osdeps_link(name, 1) }.join(", ")]

            result.map { |v| render_item(*v) }
        end

        def self.package_set_link(name, depth)
            relative =
                if depth > 0
                    "../" * depth
                end
            link = "#{relative}package_sets/#{name_to_path(name)}.html"
            "<a href=\"#{link}\">#{name}</a>"
        end
        def self.package_link(name, depth)
            relative =
                if depth > 0
                    "../" * depth
                end
            link = "#{relative}packages/#{name_to_path(name)}/index.html"
            "<a href=\"#{link}\">#{name}</a>"
        end
        def self.osdeps_link(name, depth)
            relative =
                if depth > 0
                    "../" * depth
                end
            link = "#{relative}osdeps/#{name_to_path(name)}.html"
            "<a href=\"#{link}\">#{name}</a>"
        end
        def self.file_link(file, depth)
            if file == Autoproj::OSDependencies::AUTOPROJ_OSDEPS
                return "autoproj's default OSdeps file"
            end

            pkg_set = Autoproj.manifest.each_package_set.
                find do |pkg_set|
                    File.dirname(file) == pkg_set.user_local_dir ||
                        File.dirname(file) == pkg_set.raw_local_dir
                end

            if pkg_set
                "#{Doc.package_set_link(pkg_set.name, depth)}/#{File.basename(file)}"
            end
        end

        def self.render_package_header(pkg, pkg_set)
            vcs_def = Autoproj.manifest.importer_definition_for(pkg.name)

            result = []
            result << ['defined in', Doc.package_set_link(pkg_set, 2)]
            result << ["from", render_vcs(vcs_def)]

            opt_deps = pkg.optional_dependencies.to_set
            real_deps = pkg.dependencies.find_all { |dep_name| !opt_deps.include?(dep_name) }

            real_deps = real_deps.sort.map do |name|
                Doc.package_link(name, 2)
            end
            opt_deps = opt_deps.sort.map do |name|
                Doc.package_link(name, 2)
            end

            if real_deps.empty?
                result << ['mandatory dependencies', 'none']
            else
                result << ['mandatory dependencies', real_deps.join(", ")]
            end
            if opt_deps.empty?
                result << ['optional dependencies', 'none']
            else
                result << ['optional dependencies', opt_deps.join(", ")]
            end

            osdeps = pkg.os_packages.sort.
                map do |name|
                    Doc.osdeps_link(name, 2)
                end
            if osdeps.empty?
                result << ['OS dependencies', 'none']
            else
                result << ['OS dependencies', osdeps.join(", ")]
            end

            return result.map { |v| render_item(*v) }
        end

        class Render
            attr_reader :output_dir
            def initialize(output_dir)
                @output_dir = output_dir
            end
            def package_set(pkg_set, sort_order)
                page = <<-EOT
---
title: #{pkg_set.name}
sort_info: #{sort_order}
--- name:content
<div class="body-header-list" markdown="1">
<ul>
    #{Doc.render_package_set_header(pkg_set).join("\n    ")}
</ul>
</div>
                EOT

                pkg_set_dir = File.join(output_dir, 'package_sets')
                FileUtils.mkdir_p(pkg_set_dir)
                Doc.render_page(File.join(pkg_set_dir, "#{Doc.name_to_path(pkg_set.name)}.page"), page)
                return nil
            end
            
            def package(pkg, pkg_set, pkg_api, sort_order)
                pkg_manifest = Autoproj.manifest.package_manifests[pkg.name];
                documentation =
                    if pkg_manifest
                        pkg_manifest.documentation
                    end
                if !documentation || documentation.empty?
                    documentation = "#{pkg.name} has no manifest"
                end
                documentation = documentation.split("\n").map(&:strip).join("\n")

                page = <<-EOT
---
title: Overview
sort_info: #{sort_order}
--- name:content
<div class="body-header-list" markdown="1">
<ul>
    #{Doc.render_package_header(pkg, pkg_set).join("\n    ")}
    #{if pkg_api then "<li><a href=\"#{pkg_api}\">API Documentation</a></li>" end}
</ul>
</div>

Documentation
-------------
#{documentation}
                EOT

                pkg_dir = File.join('packages', Doc.name_to_path(pkg.name))
                metainfo = [pkg_dir, pkg.name, sort_order]
                pkg_dir = File.join(output_dir, pkg_dir)

                FileUtils.mkdir_p(pkg_dir)
                Doc.render_page(File.join(pkg_dir, 'index.page'), page)

                return metainfo
            end

            def osdeps(name, data, sort_order)
                data = data.map do |files, info|
                    if info.kind_of?(Hash)
                        info = YAML.dump(info).split("\n")
                        info.shift
                        info = info.join("\n      ")
                    end
                    files = files.map { |f| Doc.file_link(f, 1) }
                    if files.size > 1
                        files = files[0..-2].join(", ") + " **and** " + files.last
                    else
                        files = files.first
                    end
                    "**Defined in** #{files} **as**\n\n    #{name}:\n      #{info}"
                end

                page = <<-EOT
---
title: #{name}
sort_info: #{sort_order}
---
#{data.join("\n")}
                EOT

                dir = File.join(output_dir, 'osdeps')
                FileUtils.mkdir_p dir
                Doc.render_page(File.join(dir, "#{Doc.name_to_path(name)}.page"), page)
                nil
            end
        end
    end
end

