module Rock
    module Doc
        class << self
            # If set, this is the base directory under which the API
            # documentation for the packages is present
            #
            # The documentation of a given package is expected to be in
            # api_dir/package_name. For instance, the documentation for
            # drivers/hokuyo is supposed to be in
            #
            #   api_dir/drivers/hokuyo/index.html
            #
            attr_accessor :api_dir

            # api_dir, but usable in links in the generated HTML
            attr_accessor :link_api_dir
        end

        def self.render_item(name, value = nil)
            if value
                "<li><b>#{name}</b>: #{value}</li>"
            else
                "<li><b>#{name}</b></li>"
            end
        end

        # Obscures an email using HTML entities
        def self.obscure_email(email)
            return nil if email.nil? #Don't bother if the parameter is nil.
            lower = ('a'..'z').to_a
            upper = ('A'..'Z').to_a
            email.split('').map { |char|
                output = lower.index(char) + 97 if lower.include?(char)
                output = upper.index(char) + 65 if upper.include?(char)
                output ? "&##{output};" : (char == '@' ? '&#0064;' : char)
            }.join
        end

        @help_id = 0
        def self.allocate_help_id
            @help_id += 1
        end

        def self.help(doc)
            id = allocate_help_id
            "<span class=\"help_trigger\" id=\"#{id}\"><img src=\"{relocatable: /img/help.png}\" /></span><div class=\"help\" id=\"help_#{id}\">#{doc}</div>"
        end

        def self.render_page(path, content)
            if File.file?(content)
                content = File.read(content)
            end
            if File.file?(path)
                return if File.read(path) == content
            end

            FileUtils.mkdir_p(File.dirname(path))
            File.open(path, 'w') do |io|
                io.puts content
            end
        end

        def self.name_to_path(name)
            name.gsub(/[^\w]/, '_')
        end

        def self.render_vcs(vcs)
            if vcs.raw
                first = true
                raw_info = vcs.raw.map do |pkg_set, vcs_info|
                    fragment = render_one_vcs(vcs_info)
                    if !first
                        fragment = "<span class=\"vcs_override\">overriden in #{pkg_set}</span>" + fragment
                    end
                    first = false
                    fragment
                end
                raw_vcs = "<div class=\"vcs\">Rock short definition<span class=\"toggle\">show/hide</span><div class=\"vcs_info\">#{raw_info.join("\n")}</div></div>"
            end

            raw_vcs +
            "<div class=\"vcs\">Autoproj definition<span class=\"toggle\">show/hide</span><div class=\"vcs_info\">#{render_one_vcs(vcs)}</div></div>"
        end

        def self.render_one_vcs(vcs)
            if vcs.kind_of?(Hash)
                options = vcs.dup
                type = options.delete('type')
                url  = options.delete('url')
            else 
                options = vcs.options
                type = vcs.type
                url = vcs.url
            end

            value = []
            if type
                value << ['type', type]
            end
            if url
                value << ['url', url]
            end
            value = value.concat(options.to_a.sort_by { |k, _| k.to_s })
            value = value.map do |key, value|
                if value.respond_to?(:to_str) && File.file?(value)
                    value = Pathname.new(value).relative_path_from(Pathname.new(Autoproj.root_dir))
                elsif value =~ /git:\/\/(.*)\.git/
                    value = "<a href=\"http://#{$1}\">#{value}</a>"
                end
                "#{key}: #{value}"
            end
            value = "<pre class=\"vcs\">\n  - #{value.join("\n    ")}</pre>"
        end

        def self.render_package_set_header(pkg_set)
            result = []
            result << ['name', pkg_set.name]

            if pkg_set.empty?
                result << ['is empty']
                return result.map { |v| render_item(*v) }
            end

            result << ["imported from", render_vcs(pkg_set.vcs)]

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
            "<a href=\"#{link}\" markdown=\"0\">#{name}</a>"
        end
        def self.package_link(name, depth)
            relative =
                if depth > 0
                    "../" * depth
                end
            link = "#{relative}packages/#{package_name_to_path(name)}/index.html"
            "<a href=\"#{link}\" markdown=\"0\">#{name}</a>"
        end
        def self.osdeps_link(name, depth)
            relative =
                if depth > 0
                    "../" * depth
                end
            link = "#{relative}osdeps/#{name_to_path(name)}.html"
            "<a href=\"#{link}\">#{name}</a>"
        end
        def self.api_link(name, link_name = "API")
            "<a href=\"#{link_api_dir}/#{name}\">#{link_name}</a>"
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

        def self.render_package_header(pkg)
            depth = if File.basename(pkg.name) == pkg.name then 2 else 3 end

            pkg, pkg_set = pkg.pkg, pkg.pkg_set
            vcs_def = Autoproj.manifest.importer_definition_for(pkg.name)

            result = []
            result << ['name', pkg.name]

            # WORKAROUND: the next autoproj version will always have a PackageManifest object (just empty if no manifest.xml)
            if pkg.description
                authors = pkg.description.xml.xpath('//author').map(&:content).
                    map { |s| obscure_email(s) }.
                    join(", ")
                result << ["authors", authors]
                result << ["license", pkg.description.xml.xpath('//license').map(&:content).join(", ")]
                urls = pkg.description.xml.xpath('//url').map(&:to_s).
                    map { |s| "<a href=\"#{s}\">#{s}</a>" }
                result << ["URL", urls.join(" ")]
            else
                result << ["authors", ""]
                result << ["license", ""]
                result << ["URL", ""]
            end

            opt_deps = pkg.optional_dependencies.to_set
            real_deps = pkg.dependencies.find_all { |dep_name| !opt_deps.include?(dep_name) }

            real_deps = real_deps.sort.map do |name|
                Doc.package_link(name, depth)
            end
            opt_deps = opt_deps.sort.map do |name|
                Doc.package_link(name, depth)
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
                    Doc.osdeps_link(name, depth)
                end
            if osdeps.empty?
                result << ['OS dependencies', 'none']
            else
                result << ['OS dependencies', osdeps.join(", ")]
            end


            import_info = []
            doc = "in autoproj, a package set is used to declare packages so that they can be imported and built. To be able to build a package, one should therefore add the relevant package set to its build configuration by copy/pasting one of the following blocks (either the Rock short definition or the Autoproj definition) into the package_sets section of autoproj/manifest. See also <a href=\"{relocatable: /documentation/tutorials/190_installing_packages.html}\">this tutorial</a>."
            import_info << ['defined in package set', Doc.package_set_link(pkg_set, 3) + Doc.help(doc) + render_vcs(Autoproj.manifest.package_set(pkg_set).vcs)]
            import_info << ["imported from", render_vcs(vcs_def)]

            return result.map { |v| render_item(*v) }, import_info.map { |v| render_item(*v) }
        end

        def self.render_main_list(title, sort_info, elements, additional_header = nil, attributes = Hash.new)
            result = []
            if title
                result << "---"
                result << "title: #{title}"
                result << "sort_info: #{sort_info}"
                result << "---"
            end
            result << "<script type=\"text/javascript\" src=\"{relocatable: /scripts/jquery.selectfilter.js}\"></script>"
            result << "<script type=\"text/javascript\">"
            result << "  jQuery(document).ready(function(){"
            result << "  jQuery(\"div#index-table\").selectFilter();"
            result << "});"
            result << "</script>"

            result.concat(additional_header) if additional_header

            result << "<div name=\"index_filter\" id=\"index-table\">"
            index = 0
            elements.each do |el|
                index += 1
                data, attributes = yield(el)
                if attributes
                    table_attributes = attributes.map { |k, v| " #{k}=\"#{v}\"" }.join("")
                end
                result << "<table class=\"short_doc#{" list_alt" if index % 2 == 0}\"#{table_attributes}>"
                result << data
                result << "</table>"
            end
            result << "</div>"
            result.flatten.join("\n")
        end

        def self.render_package_set_list(package_sets, level, sort_info = 0)
            render_main_list("Package Set Index", sort_info, package_sets.sort_by(&:name)) do |pkg_set|
                "<tr><td>#{package_set_link(pkg_set.name, level)}</td></tr>"
            end
        end

        def self.render_package_list(packages, level, sort_info = 0)
            tags = Hash.new(0)
            packages.each do |pkg|
                if pkg.manifest
                    pkg.manifest.tags.each do |tag|
                        tags[tag] += 1
                    end
                end
            end
            tagcloud = []
            tagcloud << "<script type=\"text/javascript\" src=\"{relocatable: /scripts/jquery.tagcloud.min.js}\"></script>"
            tagcloud << <<-EOSCRIPT
<script type="text/javascript">
$.tagcloud.defaults.type = 'list';
$.tagcloud.defaults.sizemin = 10;
jQuery(document).ready(function(){
  $("ul#tags").children("li").click(function(){
     var el = $(this);
     $("input.index_filter").each(function(i, filter){
         if (filter.value) {
             filter.value = filter.value + " tag:" + el.text();
         } else {
             filter.value = "tag:" + el.text();
         }
        $("input.index_filter").keyup();
     });
  });
  $("ul#tags").tagcloud();
});
</script>
            EOSCRIPT
            tagcloud << "<div class=\"tagcloud\">"
            tagcloud << "<ul id=\"tags\">"
            tags.to_a.sort_by(&:first).each do |tag, value|
                tagcloud << "<li value=\"#{value}\">#{tag}</li>"
            end
            tagcloud << "</ul>"
            tagcloud << "</div>"
            render_main_list("Package Index", sort_info, packages.sort_by(&:name), tagcloud) do |pkg|
                tags =
                    if m = pkg.manifest
                        m.tags.sort
                    else []
                    end

                html = ["<tr><td>#{package_link(pkg.name, level)}</td><td class=\"align-right\">#{if pkg.has_api? then api_link(pkg.name, "[API]") end}</td></tr>",
                    "<tr><td colspan=\"2\" class=\"short_doc\">#{pkg.short_documentation}</td></tr>"]
                [html, Hash['tags' => tags]]
            end
        end

        def self.render_osdeps_list(osdeps, level, sort_info = 0)
            render_main_list("OS Dependencies Index", sort_info, osdeps.sort) do |osdeps_name, osdeps_def|
                "<tr><td>#{osdeps_link(osdeps_name, level)}</td></tr>"
            end
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
            
            def package(pkg, sort_order)
                documentation = pkg.documentation
                documentation = documentation.split("\n").map(&:strip).join("\n")

                pkg_info, import_info = Doc.render_package_header(pkg)
                page = <<-EOT
---
title: Overview
sort_info: #{sort_order}
--- name:content
#{documentation}

Package Info
------------
<div class="body-header-list" markdown="1">
<ul>
    #{pkg_info.join("\n    ")}
    #{if pkg.has_api? then "<li>#{Doc.api_link(pkg.name, "API Documentation")}</li>" end}
</ul>
</div>

Import Info
-----------
<div class="body-header-list" markdown="1">
<ul>
    #{import_info.join("\n    ")}
</ul>
</div>

                EOT

                pkg_dir = File.join('packages', Doc.package_name_to_path(pkg.name))
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

