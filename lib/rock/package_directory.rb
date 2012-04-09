require 'rock/doc'
require 'utilrb/logger'
require 'vizkit'

module Rock
    module Doc
        class PackageDirectory
            extend Logger::Root('PackageDirectory', Logger::WARN)

            TEMPLATE_DIR = File.expand_path(File.join('templates', 'html'), File.dirname(__FILE__))

            SORT_INFO_PACKAGE_SETS_INDEX = 2
            SORT_INFO_PACKAGE_SETS       = 10

            SORT_INFO_PACKAGES_INDEX     = 9
            SORT_INFO_PACKAGES           = 10

            SORT_INFO_OS_PACKAGES_INDEX  = 3
            SORT_INFO_OS_PACKAGES        = 10

            SORT_INFO_OROGEN_TYPES_INDEX = 100
            SORT_INFO_OROGEN_TYPES       = 110

            SORT_INFO_OROGEN_TASKS_INDEX = 101
            SORT_INFO_OROGEN_TASKS       = 110

            attr_reader :output_dir

            # The set of index.page pages that have been generated so far. It is
            # used to generate them only once per session
            attr_reader :generated_indexes

            # If set, the API documentation for a package is supposed to be
            # stored in api_dir/package/name. The associated information can be
            # retrieved with has_api? and api_link
            attr_accessor :api_dir

            # If set, this is the website-relative path of the API directory. It
            # defaults to "/api"
            attr_accessor :api_base_url

            def initialize(output_dir)
                @output_dir = File.expand_path(output_dir)
                @generated_indexes = Set.new
                @handle_vizkit = false
                @api_base_url = "/api"
            end

            @templates = Hash.new
            def self.load_template(full_path)
                if template = @templates[full_path]
                    return template
                end
                @templates[full_path] = ERB.new(File.read(full_path), nil, nil, full_path.gsub(/[\/\.-]/, '_'))
            end

            def self.template_path(*relpath)
                if relpath.empty?
                    TEMPLATE_DIR
                else
                    File.expand_path(File.join(*relpath), TEMPLATE_DIR)
                end
            end

            def self.render_template(*path)
                binding = path.pop
                path = template_path(*path)
		template = load_template(path)
                template.result(binding)
            end

            def self.render_list(list_data, additional_header = nil)
                render_template('main_list_fragment.page', binding)
            end

            module RenderingContextExtension
                attr_accessor :package_directory
                def link_to(obj)
                    package_directory.link_to(obj)
                end
                def render_object(object, *template_path)
                    package_directory.render_object(object, *template_path)
                end
                def has_api?(pkg)
                    package_directory.has_api?(pkg)
                end
                def api_link(pkg, text)
                    package_directory.api_link(pkg, text)
                end

                @@help_id = 0
                def self.allocate_help_id
                    @@help_id += 1
                end

                def help_tip(doc)
                    id = RenderingContextExtension.allocate_help_id
                    "<span class=\"help_trigger\" id=\"#{id}\"><img src=\"{relocatable: /img/help.png}\" /></span><div class=\"help\" id=\"help_#{id}\">#{doc}</div>"
                end
            end

            def rendering_context_for(object)
                context = Rock::Doc::HTML.rendering_context_for(object)
                context.extend RenderingContextExtension
                context.package_directory = self

                case object
                when Class
                    if object <= Typelib::Type
                        # Add producer / consumer information
                        if orogen_type_producers.has_key?(object.name)
                            context.produced_by.concat(orogen_type_producers[object.name])
                        end
                        if orogen_type_consumers.has_key?(object.name)
                            context.consumed_by.concat(orogen_type_consumers[object.name])
                        end
                        if orogen_type_vizkit.has_key?(object.name)
                            context.displayed_by.concat(orogen_type_vizkit[object.name])
                        end
                    end
                end
                context
            end


            def render_object(object, *template_path)
                options = { :context => rendering_context_for(object) }
                template_path << options
                Rock::Doc::HTML.render_object(object, *template_path)
            end

            def write_file(output_file, content)
                output_file = File.expand_path(output_file, output_dir)
                FileUtils.mkdir_p(File.dirname(output_file))
                if File.file?(output_file)
                    if File.read(output_file) == content
                        PackageDirectory.debug "not writing #{output_file}: did not change"
                        return
                    end
                end

                PackageDirectory.debug "writing #{output_file}"
                File.open(output_file, 'w') do |io|
                    io.write content
                end
            end

            def write(output_file, *template_path)
                page = PackageDirectory.render_template(*template_path)
                write_file(output_file, page)
            end

            def write_object_page(output_file, index, object, *template_path)
                fragment = render_object(object, *template_path)
                write(output_file, 'object_page.page', binding)
            end
            
            def render_tagcloud(tags)
                PackageDirectory.render_template('tagcloud.page', binding)
            end

            def link_to(obj)
                relative_path = nil
                case obj
                when Orocos::Spec::TaskContext
                    if Orocos.available_task_models.include?(obj.name)
                        relative_path = "tasks/#{obj.name}.html"
                    else
                        return obj.name
                    end
                when Autoproj::PackageSet
                    relative_path = "sets/#{obj.name.gsub('.', '_')}.html"
                when Autoproj::PackageDefinition
                    # The package might not be available on this installation,
                    # in which case we don't link to anything
                    if available_autoproj_packages.include?(obj.name)
                        relative_path = "pkg/#{obj.name}/index.html"
                    else
                        relative_path = false
                    end
                when Rock::Doc::OSPackage
                    relative_path = "osdeps/#{obj.name}.html"
                when Class
                    if obj <= Typelib::Type
                        if obj <= Typelib::NumericType
                            return Doc::HTML.escape_html(obj.name)
                        elsif obj <= Typelib::ArrayType
                            return "#{link_to(obj.deference)}[#{obj.length}]"
                        elsif obj <= Typelib::ContainerType
                            return "#{Doc::HTML.escape_html(obj.container_kind)}&lt;#{link_to(obj.deference)}&gt;"
                        elsif !orogen_types.include?(obj)
                            if opaque = Orocos.master_project.find_opaque_for_intermediate(obj)
                                return link_to(opaque)
                            end
                        end

                        relative_path = "types/#{typename_to_path(obj, "html")}"
                    end
                when Rock::Doc::VizkitWidget
                    relative_path = false
                end

                if relative_path
                    text =
                        if obj.respond_to?(:name)
                            obj.name
                        else obj.to_s
                        end
                    text = Doc::HTML.escape_html(text)

                    "<a href=\"{relocatable: /#{relative_path}}\">#{text}</a>"
                elsif relative_path.nil?
                    PackageDirectory.warn "cannot generate link to #{text}(#{obj})"
                    raise
                else
                    PackageDirectory.debug "did not generate link to #{text}(#{obj})"
                    text
                end
            end

            def has_api?(pkg)
                if api_dir
                    File.directory?(File.join(api_dir, *pkg.name.split('/')))
                end
            end

            def api_link(pkg, text)
                "<a href=\"{relocatable: #{File.join(api_base_url, pkg.name)}}\">#{text}</a>"
            end

            def prepare_sections(objects, index, root_dir, separator, name_path, section_path, template)
                full_path = root_dir.dup
                current_name = []
                section_path.each_with_index do |part, i|
                    current_name << name_path[i]
                    filter = /^#{separator}?#{Regexp.quote(current_name.join(separator))}/
                    full_path = File.join(full_path, part)

                    if !generated_indexes.include?(index_path = File.join(full_path, "index.page"))
                        FileUtils.mkdir_p(full_path)

                        filtered_objects = objects.
                            find_all { |obj| obj.name =~ filter }

                        write_index(filtered_objects, index_path, template,
                                   :title => current_name.join(separator) + separator,
                                   :sort_info => index)
                        generated_indexes << index_path
                    end
                end
            end

            def write_index(objects, target_path, template, options = Hash.new)
                options = Kernel.validate_options options,
                    :title => "",
                    :routed_title => nil,
                    :sort_info => 0

                title = options[:title]
                routed_title = options[:routed_title] || options[:title]
                sort_info = options[:sort_info]
                write(target_path, template, binding)
            end

            attr_reader :autoproj_packages
            attr_reader :available_autoproj_packages
            attr_reader :autoproj_package_sets
            attr_reader :autoproj_osdeps
            attr_reader :orogen_task_models
            attr_reader :orogen_types
            attr_reader :orogen_type_producers
            attr_reader :orogen_type_consumers
            attr_reader :orogen_type_vizkit
            attr_reader :orogen_type_vizkit3d

            attr_predicate :handle_vizkit?, true

            def prepare
                @autoproj_packages = Autoproj.manifest.packages.values.sort_by(&:name).
                    find_all { |pkg| File.directory?(pkg.autobuild.srcdir) }
                @available_autoproj_packages = autoproj_packages.map(&:name).to_set

                @autoproj_package_sets = Autoproj.manifest.each_package_set.sort_by(&:name)
                @autoproj_osdeps = Autoproj.osdeps.all_definitions.keys.sort.map do |osdep_name|
                    Rock::Doc::OSPackage.new(osdep_name)
                end
                @orogen_type_producers = Hash.new { |h, k| h[k] = Array.new }
                @orogen_type_consumers = Hash.new { |h, k| h[k] = Array.new }

                @orogen_task_models = Orocos.available_task_models.keys.sort.map do |model_name|
                    begin
                        PackageDirectory.debug "loading task model #{model_name}"
                        task_model = Orocos.task_model_from_name(model_name)
                        task_model.each_input_port do |p|
                            orogen_type_consumers[p.type.name] << p
                        end
                        task_model.each_output_port do |p|
                            orogen_type_producers[p.type.name] << p
                        end
                        task_model
                    rescue Interrupt; raise
                    rescue Exception => e
                        PackageDirectory.warn "cannot load task model #{model_name}: #{e.exception}"
                        next
                    end
                end.compact

                @orogen_types = Orocos.available_types.keys.sort.map do |type_name|
                    typekit =
                        begin
                            PackageDirectory.debug "loading typekit for #{type_name}"
                            Orocos.load_typekit_for(type_name, false)
                        rescue Interrupt; raise
                        rescue Exception => e
                            PackageDirectory.warn "cannot load typekit for #{type_name}: #{e.message}"
                            next
                        end

                    type = Orocos.registry.get(type_name)
                    if typekit.m_type?(type)
                        PackageDirectory.debug "ignoring #{type_name}: is an m-type"
                        next
                    elsif !(type <= Typelib::ArrayType)
                        type
                    else
                        PackageDirectory.debug "ignoring #{type.name}: is an array"
                        nil
                    end
                end.compact.to_value_set

                @orogen_type_vizkit = Hash.new { |h, k| h[k] = Array.new }
                @orogen_type_vizkit3d = Hash.new { |h, k| h[k] = Array.new }
                if handle_vizkit?
                    widgets = Vizkit.default_loader.available_widgets
                    widgets.each do |widget|
                        Vizkit.default_loader.registered_for(widget).each do |type_name|
                            klass =
                                if Vizkit.default_loader.vizkit3d_widgets.include?(widget)
                                    Rock::Doc::Vizkit3DWidget
                                else
                                    Rock::Doc::VizkitWidget
                                end

                            orogen_type_vizkit[type_name] << klass.new(widget)
                        end
                    end
                    Vizkit.vizkit3d_widget.plugins.each do |libname, plugin_name| 
                        plugin = Vizkit::vizkit3d_widget.createPlugin(libname, plugin_name)
                        plugin.plugins.each_value do |adapter|
                            orogen_type_vizkit3d[adapter.expected_ruby_type.name] << plugin
                        end
                    end
                end
            end

            def render_api_virtual
                return if !api_dir

                result = YAML::Omap.new
                autoproj_packages.each do |pkg|
                    if has_api?(pkg)
                        result << ["#{api_base_url}/#{pkg.name}", nil]
                   end
                end
                if !result.empty?
                    write_file('api.virtual', "\\" + YAML.dump(result))
                end
            end

            def render_autoproj_packages(match = nil)
                if match
                    packages = autoproj_packages.find_all { |pkg| pkg.name =~ match }
                else
                    packages = autoproj_packages
                end

                write_index(packages,
                            File.join('pkg', 'index.page'), 'autoproj_package_list.page',
                           :title => 'Package Index',
                           :routed_title => 'Packages',
                           :sort_info => SORT_INFO_PACKAGES_INDEX)
                packages.each_with_index do |pkg, index|
                    section = pkg.name.split('/')[0..-2]

                    prepare_sections(packages, index + SORT_INFO_PACKAGES,
                                     'pkg', '/', section, section, 'autoproj_package_list.page')
                    write_object_page(File.join('pkg', pkg.name.split('/'), 'index.page'), index + SORT_INFO_PACKAGES, pkg, 'autoproj_package_fragment.page')
                end
            end

            def render_autoproj_package_sets
                write_index(autoproj_package_sets,
                            File.join('sets', 'index.page'), 'autoproj_package_set_list.page',
                           :title => "Package Set Index",
                           :routed_title => "Package Sets",
                           :sort_info => SORT_INFO_PACKAGE_SETS_INDEX)
                autoproj_package_sets.each_with_index do |pkg_set, index|
                    write_object_page(File.join('sets', "#{pkg_set.name.gsub('.', '_')}.page"), index + SORT_INFO_PACKAGE_SETS, pkg_set, 'autoproj_package_set_fragment.page')
                end
            end

            def render_autoproj_osdeps
                write_index(autoproj_osdeps,
                            File.join('osdeps', 'index.page'), 'autoproj_osdeps_list.page',
                            :title => 'OS Packages Index',
                            :routed_title => 'OS Packages',
                            :sort_info => SORT_INFO_OS_PACKAGES_INDEX
                           )
                autoproj_osdeps.each_with_index do |obj, index|
                    write_object_page(File.join('osdeps', "#{obj.name}.page"), index + SORT_INFO_OS_PACKAGES, obj, 'autoproj_osdeps_fragment.page')
                end
            end

            def render_orogen_tasks
                write_index(
                    orogen_task_models,
                    File.join('tasks', 'index.page'), 'orogen_task_list.page',
                    :title => "oroGen Tasks Index",
                    :routed_title => 'oroGen Tasks',
                    :sort_info => SORT_INFO_OROGEN_TASKS_INDEX)
                orogen_task_models.each_with_index do |t, index|
                    write_object_page(File.join('tasks', "#{t.name}.page"), SORT_INFO_OROGEN_TASKS + index, t, 'orogen_task_fragment.page')
                end
            end

            def typename_join_template_args(args)
                result = []
                args.each do |str|
                    if str.size == 1
                        result << str.first
                    else
                        result << str.join(",")
                    end
                end
                result.join(",")
            end

            def typename_split(type)
                tokens = Typelib::GCCXMLLoader.template_tokenizer(type.name)
                path = []
                while !tokens.empty?
                    if tokens.first == '<'
                        args = Typelib::GCCXMLLoader.collect_template_arguments(tokens)
                        path.last << "<" << typename_join_template_args(args) << ">"
                    else
                        path.concat(tokens.shift.split('/'))
                    end
                end
                # Remove empty path due to root /
                path.delete_if { |p| p.empty? }
                path
            end

            def typename_to_path(type, ext = "page")
                names = typename_split(type)
                path  = names.map { |p| p.gsub(/[\/<>]/, '_') } 
                path[-1] += ".#{ext}"
                path.join("/")
            end

            def render_orogen_types
                orogen_types = self.orogen_types.sort_by(&:name)
                write_index(orogen_types,
                            File.join('types', 'index.page'), 'orogen_type_list.page',
                           :title => 'oroGen Types Index',
                           :routed_title => 'oroGen Types',
                           :sort_info => SORT_INFO_OROGEN_TYPES_INDEX)

                orogen_types.each_with_index do |t, index|
                    names = typename_split(t)
                    path  = names.map { |p| p.gsub(/[\/<>]/, '_') } 
                    path[-1] += ".page"
                    prepare_sections(orogen_types, index + SORT_INFO_OROGEN_TYPES,
                                     'types', '/', names, path[0..-2], 'orogen_type_list.page')
                    write_object_page(File.join('types', *path), SORT_INFO_OROGEN_TYPES + index, t, 'type_fragment.page')
                end
            end
        end
    end
end
