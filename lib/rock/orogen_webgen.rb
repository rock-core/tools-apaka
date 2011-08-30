module Rock
    module Doc
        class << self
            attr_reader :orogen_to_autoproj
            attr_reader :task_to_autoproj
            attr_reader :type_to_autoproj
            attr_accessor :autoproj_packages
        end
        @orogen_to_autoproj = Hash.new
        @task_to_autoproj = Hash.new
        @type_to_autoproj = Hash.new
        @autoproj_packages = Array.new

        def self.escape_html(string)
            string.
                gsub('<', '&lt;').
                gsub('>', '&gt;')
        end

        def self.orogen_type_link(type, from)
            if type < Typelib::ArrayType
                return "#{orogen_type_link(type.deference, from)}[#{type.length}]"
            elsif type < Typelib::ContainerType
                return "#{type.container_kind}&lt;#{orogen_type_link(type.deference, from)}&gt;"
            end

            if !(autoproj_name = type_to_autoproj[type.name])
                return escape_html(type.name)
            end

            if from == :orogen_types || from == :orogen_tasks
                link = "../orogen_types/#{name_to_path(type.name)}.html"
                return "<a href=\"#{link}\" markdown=\"0\">#{escape_html(type.name)}</a>"
            elsif from == :autoproj_packages
                link = "../#{name_to_path(autoproj_name)}/types.html##{name_to_path(type.name)}"
                return "<a href=\"#{link}\" markdown=\"0\">#{escape_html(type.name)}</a>"
            else
                raise ArgumentError, "#{from} was expected to be one of :orogen_types, :autoproj_packages"
            end
        end

        def self.orogen_task_link(task, from)
            if !(autoproj_name = task_to_autoproj[task.name])
                return escape_html(task.name)
            end

            if from == :orogen_types || from == :orogen_tasks
                link = "../orogen_tasks/#{name_to_path(task.name)}.html"
                return "<a href=\"#{link}\" markdown=\"0\">#{escape_html(task.name)}</a>"
            elsif from == :autoproj_packages
                return autoproj_package_link(autoproj_name, from, "tasks.html##{name_to_path(task.name)}")
            else
                raise ArgumentError, "#{from} was expected to be one of :orogen_types, :autoproj_packages"
            end
        end

        def self.package_name_to_path(path)
            elements = Pathname(path).enum_for(:each_filename).to_a
            if elements.size == 1
                return elements.first
            else
                dirname  = elements.first
                filename = File.join(*elements)
                File.join(dirname, name_to_path(filename))
            end
        end

        def self.autoproj_package_link(pkg, from, additional = nil)
            if pkg.respond_to?(:name)
                pkg = pkg.name
            end

            path = package_name_to_path(pkg)
            if from == :orogen_types || from == :orogen_tasks
                link = "../#{path}.html"
            elsif from == :autoproj_packages
                link = "#{path}"
                if additional
                    link = "#{link}/#{additional}"
                end
            else
                raise ArgumentError, "#{from} was expected to be one of :orogen_types, :autoproj_packages"
            end

            return "<a href=\"#{link}\" markdown=\"0\">#{escape_html(task.name)}</a>"
        end

        class OrogenRender
            def self.load_orogen_project(master_project, name, debug)
                master_project.load_orogen_project(name)
            rescue Exception => e
                if debug
                    raise
                end
                STDERR.puts "WARN: cannot load the installed oroGen project #{name}"
                STDERR.puts "WARN:     #{e.message}"
            end

            def self.render_task_list(tasks)
                Doc.render_main_list(nil, 0, tasks.sort_by(&:name)) do |task|
                    "<tr><td>#{Doc.orogen_task_link(task.model, :orogen_tasks)}</td></tr>"
                end
            end

            def self.render_type_list(types)
                Doc.render_main_list(nil, 0, types.sort_by(&:name)) do |type|
                    "<tr><td>#{Doc.orogen_type_link(type.type, :orogen_types)}</td></tr>"
                end
            end

            class ObjectDefinition
                attr_reader :package_name
                attr_reader :fragment

                def initialize(package_name, fragment)
                    @package_name = package_name
                    @fragment = fragment
                end
            end

            class TypeDefinition < ObjectDefinition
                attr_reader :type
                attr_reader :intermediate_type

                def opaque?; !!@intermediate_type end

                def initialize(type, intermediate_type, package_name, fragment)
                    super(package_name, fragment)
                    @type = type
                    @intermediate_type = intermediate_type
                end

                def name; type.name end

                def to_webgen_page(depth, sort_order, inputs, outputs)
                    page = <<-EOPAGE
---
title: #{Doc.escape_html(name)}
sort_info: #{sort_order}
---
Defined in the typekit of #{Doc.package_link(package_name, depth)}
                    EOPAGE

                    inputs = inputs.map do |task|
                        Doc.orogen_task_link(task.model, :orogen_types)
                    end
                    outputs = outputs.map do |task|
                        Doc.orogen_task_link(task.model, :orogen_types)
                    end

                    page << "<table><tr>"
                    if !outputs.empty?
                        page << "<td><ul class=\"body-header-list half-size\" style=\"margin:0;\">"
                        page << Doc.render_item("Produced by")
                        outputs.sort.each do |task|
                            page << "<li>#{task}</li>"
                        end
                        page << "</ul></td>"
                    end
                    if !inputs.empty?
                        page << "<td><ul class=\"body-header-list half-size\" style=\"margin:0;\">"
                        page << Doc.render_item("Consumed by")
                        inputs.sort.each do |task|
                            page << "<li>#{task}</li>"
                        end
                        page << "</ul></td>"
                    end
                    page << "</tr></table>"

                    page << "\n\n#{fragment}"
                    page
                end
            end


            class TaskDefinition < ObjectDefinition
                attr_reader :model

                def initialize(model, package_name, fragment)
                    super(package_name, fragment)
                    @model = model
                end

                def name; model.name end

                def to_webgen_page(depth, sort_order)
                    result = <<-EOPAGE
---
title: #{name}
sort_info: #{sort_order}
---
Defined in the task library of #{Doc.package_link(package_name, depth)}

#{fragment}
                    EOPAGE
                end
            end

            def self.render_all(output_dir, debug)
                render = OrogenRender.new(output_dir, Doc.api_dir)

                require 'orocos'

                Orocos.load
                master_project = Orocos::Generation::Project.new

                all = []
                Orocos.available_projects.each_key do |project_name|
                    autoproj_name = Doc.orogen_to_autoproj[project_name]
                    if !autoproj_name
                        STDERR.puts "WARN: cannot find the autoproj package for the oroGen project #{project_name}"
                        next
                    end

                    project = 
                        begin load_orogen_project(master_project, project_name, debug)
                        rescue Interrupt
                            raise
                        rescue Exception => e
                            STDERR.puts "WARN: cannot load project #{project_name}, ignoring it"
                            next
                        end

                    if project.typekit
                        types = project.typekit.self_types
                        types.each do |t|
                            Doc.type_to_autoproj[t.name] = autoproj_name
                        end
                    end

                    tasks = project.self_tasks
                    tasks.each do |t|
                        Doc.task_to_autoproj[t.name] = autoproj_name
                    end

                    all << project
                end

                # type_mappings = Hash.new
                # all_types.sort_by(&:first).each do |type_name, autoproj_name, fragment, type_class|
                #     convertion = type_class.convertion_to_ruby
                #     if convertion
                #         if convertion[0]
                #             type_mappings[type_name] = convertion[0].name
                #         else 
                #             type_mappings[type_name] = "converted to an unknown type"
                #         end
                #     end
                # end
                # @type_mappings = type_mappings

                ## Discover all tasks and types registered on this system
                all_types, all_tasks = [], []
                all.each do |project|
                    types, tasks = render.render_project(project)
                    all_types.concat(types)
                    all_tasks.concat(tasks)
                end

                # Sort the task models by their input/output types
                # (for display in the type pages)
                input_ports = Hash.new { |h, k| h[k] = ValueSet.new }
                output_ports = Hash.new { |h, k| h[k] = ValueSet.new }
                all_tasks.each do |task|
                    task.model.each_input_port do |p|
                        input_ports[p.type.name] << task
                    end
                    task.model.each_dynamic_input_port do |p|
                        if p.type
                            input_ports[p.type.name] << task
                        end
                    end
                    task.model.each_output_port do |p|
                        output_ports[p.type.name] << task
                    end
                    task.model.each_dynamic_output_port do |p|
                        if p.type
                            output_ports[p.type.name] << task
                        end
                    end
                end

                # Local variable used to sort the pages from the pov of webgen
                sort_order = 0

                ## Generate all standalone type pages, and the oroGen type index
                ## page
                types_dir   = File.join(output_dir, "orogen_types")
                FileUtils.mkdir_p(types_dir)
                all_types.sort_by(&:name).each do |type|
                    page = type.to_webgen_page(1, sort_order += 1, input_ports[type.name], output_ports[type.name])
                    Doc.render_page(File.join(types_dir, "#{Doc.name_to_path(type.name)}.page"), page)
                end
                render_type_index(all_types, types_dir)

                ## Generate all standalone task pages, and the oroGen task index
                ## page
                tasks_dir   = File.join(output_dir, "orogen_tasks")
                FileUtils.mkdir_p(tasks_dir)
                all_tasks.sort_by(&:name).each do |taskdef|
                    page = taskdef.to_webgen_page(1, sort_order += 1)
                    Doc.render_page(File.join(tasks_dir, "#{Doc.name_to_path(taskdef.name)}.page"), page)
                end
                render_task_index(all_tasks, tasks_dir)
            end

            def self.render_task_index(tasks, tasks_dir)
                task_list = render_task_list(tasks)
                page = <<-EOPAGE
---
title: oroGen Tasks
sort_info: 0
---
This is the list of all tasks defined in oroGen projects, i.e. all the components that are available in the system.

#{task_list}
                EOPAGE
                Doc.render_page(File.join(tasks_dir, "index.page"), page)
            end

            def self.render_type_index(types, types_dir)
                type_list = render_type_list(types)
                page = <<-EOPAGE
---
title: oroGen Types
sort_info: 0
---
This page lists all the types that have been exported through oroGen, i.e. that are being used in oroGen tasks.

For each type, three informations are given:

 * <b>the C++ type definition</b>, that is the definition of the type in C++ (as given to oroGen). [Opaque types](../../documentation/orogen/opaque_types.html) are not explicitely represented in oroGen and are therefore not displayed.
 * <b>Logging</b> is the type definition as saved in log files. It differs from the C++ type only for opaque types.
 * <b>Ruby</b> is the type definition as manipulated in Ruby. It differs from the C++ type for opaque types, and in cases where [custom convertions](../../documentation/runtime/ruby_and_types.html) have been defined.

#{type_list}
                EOPAGE
                Doc.render_page(File.join(types_dir, "index.page"), page)
            end

            attr_reader :output_dir
            def initialize(output_dir, api_dir)
                @output_dir = output_dir
                @api_dir = api_dir
                if api_dir
                    index_api_dir 
                else
                    @rdoc_dirs = Array.new
                end
                @sort_order = 0
            end

            def index_api_dir
                @rdoc_dirs = Array.new
                Doc.autoproj_packages.each do |pkg|
                    rdoc_dir = Find.enum_for(:find, pkg.pkg.doc_dir).find_all do |dir|
                        File.directory?(dir) && File.exists?(File.join(dir, "rdoc.css"))
                    end
                    @rdoc_dirs << [pkg, rdoc_dir]
                end
            end

            def ruby_class_doc_path(klass)
                name = File.join(*klass.name.split('::')) + ".html"
                @rdoc_dirs.each do |pkg, dirs|
                    dirs.each do |dir|
                        path = File.join(dir, name)
                        if File.file?(path)
                            return "../../api/#{pkg.name}/#{name}"
                        end
                    end
                end
                nil
            end

            def header(name)
                "<li class=\"title\">#{name}</li>"
            end

            def render_task_fragment(task, from)
                project = task.project

                result = []
                if from != :orogen_tasks
                    result << "#{task.name}   {##{Doc.name_to_path(task.name)}}"
                    result << "-----------"
                end
                result << "<ul class=\"body-header-list\">"
                result << Doc.render_item("doc", task.doc)
                result << Doc.render_item("subclassed from", Doc.orogen_task_link(task.superclass, from))

                states = task.each_state.to_a
                if states.empty?
                    result << header("No states")
                else
                    result << header("States")
                    states.sort_by { |*v| v.map(&:to_s) }.each do |name, type|
                        result << Doc.render_item(name, type)
                    end
                end

                [[:each_input_port, "Input Ports"], [:each_output_port, "Output Ports"], [:each_property, "Properties"]].
                    each do |enum_with, kind|
                        ports = task.send(enum_with).to_a.sort_by(&:name)
                        if ports.empty?
                            result << header("No #{kind}")
                        else
                            result << header(kind)
                            ports.each do |p|
                                result << Doc.render_item(p.name, "(#{Doc.orogen_type_link(p.type, from)}) #{p.doc}")
                            end
                        end
                    end

                result << header("Operations [NOT IMPLEMENTED YET]")
                result << "</ul>"

                result.join("\n")
            end

            def render_type_definition_fragment(result, type, from)
                if type < Typelib::CompoundType
                    result << "<ul class=\"body-header-list\">"
                    type.each_field do |field_name, field_type|
                        result << Doc.render_item(field_name, Doc.orogen_type_link(field_type, from))
                    end
                    result << "</ul>"
                elsif type < Typelib::EnumType
                    result << "<ul class=\"body-header-list\">"
                    type.keys.sort_by(&:last).each do |key, value|
                        result << Doc.render_item(key, value)
                    end
                    result << "</ul>"
                else
                    raise ArgumentError, "don't know how to display #{type.name} (#{type.ancestors.map(&:name).join(", ")})"
                end
            end

            def render_type_mapping_table(typekit, type)
                intermediate_type = typekit.intermediate_type_for(type)
                "<table><tr><td>#{type.name}</td><td>#{type.cxx_name}</td><td>#{intermediate_type.name}</td></tr></table>"
            end

            def type_has_convertions?(type)
                if type.convertion_to_ruby
                    true
                elsif type < Typelib::CompoundType
                    type.enum_for(:each_field).any? do |field_name, field_type|
                        field_type.convertion_to_ruby
                    end
                elsif type < Typelib::EnumType
                    false
                else
                    raise NotImplementedError
                end
            end

            def render_convertion_spec(base_type, convertion, from)
                if spec = convertion[0]
                    if spec == Array
                        # The base type is most likely an array or a container.
                        # Display the element type as well ...
                        if base_type.respond_to?(:deference)
                            if subconv = base_type.deference.convertion_to_ruby
                                return "Array(#{render_convertion_spec(base_type.deference, subconv, from)})"
                            else
                                return "Array(#{Doc.orogen_type_link(base_type.deference, from)})"
                            end
                        end
                    end
                    if api_path = ruby_class_doc_path(convertion[0])
                        "<a href=\"#{api_path}\">#{convertion[0].name}</a>"
                    else
                        convertion[0].name
                    end

                else
                    "converted to an unspecified type"
                end
            end

            def render_type_convertion(type, from)
                result = []
                if convertion = type.convertion_to_ruby
                    result << render_convertion_spec(type, convertion, from)
                elsif type < Typelib::CompoundType
                    result << "<ul class=\"body-header-list\">"
                    type.each_field do |field_name, field_type|
                        if convertion = field_type.convertion_to_ruby
                            result << Doc.render_item(field_name, render_convertion_spec(field_type, convertion, from))
                        else
                            result << Doc.render_item(field_name, Doc.orogen_type_link(field_type, from))
                        end
                    end
                    result << "</ul>"
                else
                    raise NotImplementedError
                end
                result.join("\n")
            end

            def render_type_fragment(type, typekit, from)
                # Intermediate types that are not explicitely exported are
                # displayed only with the opaque they help marshalling
                if typekit.m_type?(type)
                    if !typekit.interface_type?(type)
                        return
                    end
                end

                result = []
                if from == :autoproj_packages
                    type_name = Doc.escape_html(type.name)
                    result << "#{type_name}   {##{Doc.name_to_path(type.name)}}"
                    result << "-" * type_name.length
                end

                if typekit.interface_type?(type.name)
                    result << "is exported by #{from == :autoproj_packages ? 'this' : 'its'} typekit (can be used in task interfaces)"
                else
                    result << "is **NOT** exported by #{from == :autoproj_packages ? 'this' : 'its'} typekit (**CANNOT** be used in task interfaces)"
                end

                if type < Typelib::CompoundType || type < Typelib::EnumType
                    if type.contains_opaques?
                        result << "<h2>C++</h2>"
                        render_type_definition_fragment(result, type, from)
                        intermediate = typekit.intermediate_type_for(type)
                        is_converted = type_has_convertions?(intermediate)
                        result << "<h2>Logging#{", Ruby" if !is_converted}</h2>"
                        render_type_definition_fragment(result, intermediate, from)
                        if is_converted
                            result << "<h2>Ruby</h2>"
                            result << render_type_convertion(intermediate, from)
                        end
                    else
                        is_converted = type_has_convertions?(type)
                        result << "<h2>C++, Logging#{", Ruby" if !is_converted}</h2>"
                        render_type_definition_fragment(result, type, from)
                        if is_converted
                            result << "<h2>Ruby</h2>"
                            result << render_type_convertion(type, from)
                        end
                    end

                elsif type < Typelib::OpaqueType
                    result << "<h2>C++</h2>"
                    result << "unknown to oroGen (this is an opaque type)"
                    intermediate = typekit.intermediate_type_for(type)
                    is_converted = type_has_convertions?(intermediate)
                    result << "<h2>Logging#{", Ruby" if !is_converted}</h2>"
                    render_type_definition_fragment(result, intermediate, from)
                    if is_converted
                        result << "<h2>Ruby</h2>"
                        result << render_type_convertion(intermediate, from)
                    end

                elsif type < Typelib::ContainerType || type < Typelib::ArrayType
                    # ignored
                    return
                end

                result.join("\n")
            end

            def render_project(project)
                package_name = Doc.orogen_to_autoproj[project.name]
                if !package_name
                    STDERR.puts "WARN: cannot find the autoproj package for the oroGen project #{project.name}"
                    return
                end
                project_dir = File.join(output_dir, "packages", Doc.package_name_to_path(package_name))

                all_types = []
                if typekit = project.typekit
                    fragments = []
                    typekit.self_types.to_a.sort_by(&:name).each do |type|
                        fragments << render_type_fragment(type, typekit, :autoproj_packages)
                    end
                    fragments = fragments.compact

                    page = <<-EOPAGE
---
title: Types
sort_info: 100
--- name:content
#{fragments.join("\n\n")}
                    EOPAGE

                    Doc.render_page(File.join(project_dir, "types.page"), page)

                    # Now render a separate page for each type.
                    typekit.self_types.to_a.sort_by(&:name).each do |type|
                        fragment = render_type_fragment(type, typekit, :orogen_types)
                        next if !fragment

                        if type.contains_opaques?
                            intermediate = typekit.intermediate_type_for(type)
                        end
                        all_types << TypeDefinition.new(type, intermediate, package_name, fragment)
                    end
                end

                all_tasks = []
                tasks = project.self_tasks
                if !tasks.empty?
                    fragments = []
                    tasks.to_a.sort_by(&:name).each do |task|
                        fragments << render_task_fragment(task, :autoproj_packages)
                    end

                    page = <<-EOPAGE
---
title: Tasks
sort_info: 200
---
#{fragments.join("\n\n")}
                    EOPAGE

                    Doc.render_page(File.join(project_dir, "tasks.page"), page)

                    # Now render a separate page for each task
                    tasks.to_a.sort_by(&:name).each do |task|
                        fragment = render_task_fragment(task, :orogen_tasks)
                        next if !fragment
                        all_tasks << TaskDefinition.new(task, package_name, fragment)
                    end
                end

                return all_types, all_tasks
            end
        end
    end
end

