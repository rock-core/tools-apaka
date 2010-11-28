module Rock
    module Doc
        class << self
            attr_reader :orogen_to_autoproj
            attr_reader :task_to_autoproj
            attr_reader :type_to_autoproj
        end
        @orogen_to_autoproj = Hash.new
        @task_to_autoproj = Hash.new
        @type_to_autoproj = Hash.new

        def self.escape_html(string)
            string.
                gsub('<', '&lt;').
                gsub('>', '&gt;')
        end

        def self.orogen_type_link(type, depth)
            if type < Typelib::ArrayType
                return "#{orogen_type_link(type.deference, depth)}[#{type.length}]"
            elsif type < Typelib::ContainerType
                return "#{type.container_kind}&lt;#{orogen_type_link(type.deference, depth)}&gt;"
            end

            relative =
                if depth > 0
                    "../" * depth
                end

            if autoproj_name = type_to_autoproj[type.name]
                link = "#{relative}packages/#{name_to_path(autoproj_name)}/types.html##{name_to_path(type.name)}"
                "<a href=\"#{link}\">#{escape_html(type.name)}</a>"
            else
                escape_html(type.name)
            end
        end

        def self.orogen_task_link(task, depth)
            relative =
                if depth > 0
                    "../" * depth
                end

            if autoproj_name = task_to_autoproj[task.name]
                link = "#{relative}packages/#{autoproj_name}/tasks.html##{name_to_path(task.name)}"
                "<a href=\"#{link}\">#{task.name}</a>"
            else
                task.name
            end
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

            def self.render_all(output_dir, debug)
                render = OrogenRender.new(output_dir)

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

                    project = load_orogen_project(master_project, project_name, debug)
                    if project.typekit
                        puts "#{project.name} #{master_project} #{project.typekit.main_project}"
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

                all.each do |project|
                    render.render_project(project)
                end
            end

            attr_reader :output_dir
            def initialize(output_dir)
                @output_dir = output_dir
            end

            def header(name)
                "<li class=\"title\">#{name}</li>"
            end

            def render_task_fragment(task, depth)
                project = task.project

                result = []
                result << "#{task.name}   {##{Doc.name_to_path(task.name)}}"
                result << "-----------"
                result << "<ul class=\"body-header-list\">"
                result << Doc.render_item("subclassed from", Doc.orogen_task_link(task.superclass, depth))

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
                                result << Doc.render_item(p.name, "(#{Doc.orogen_type_link(p.type, depth)}) #{p.doc}")
                            end
                        end
                    end

                result << header("Operations [NOT IMPLEMENTED YET]")
                result << "</ul>"

                result.join("\n")
            end

            def render_type_definition_fragment(result, type, depth)
                if type < Typelib::CompoundType
                    result << "<ul class=\"body-header-list\">"
                    type.each_field do |field_name, field_type|
                        result << Doc.render_item(field_name, Doc.orogen_type_link(field_type, depth))
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

            def render_type_fragment(type, typekit, depth)
                # Intermediate types that are not explicitely exported are
                # displayed only with the opaque they help marshalling
                if typekit.m_type?(type)
                    if !typekit.interface_type?(type)
                        return
                    end
                end

                result = []
                type_name = Doc.escape_html(type.name)
                result << "#{type_name}   {##{Doc.name_to_path(type.name)}}"
                result << "-" * type_name.length

                if typekit.interface_type?(type.name)
                    result << "is exported by this typekit (can be used in task interfaces)"
                else
                    result << "is **NOT** exported by this typekit (**CANNOT** be used in task interfaces)"
                end

                if type < Typelib::CompoundType || type < Typelib::EnumType
                    render_type_definition_fragment(result, type, depth)

                    if type.contains_opaques?
                        intermediate = typekit.intermediate_type_for(type)
                        result << "" << "contains opaque types, and is therefore marshalled as #{intermediate.name}"
                        render_type_definition_fragment(result, intermediate, depth)
                    end

                elsif type < Typelib::OpaqueType
                    intermediate = typekit.intermediate_type_for(type)
                    result << ""
                    result << "is an opaque type which is marshalled as #{Doc.orogen_type_link(intermediate, depth)}"

                elsif type < Typelib::ContainerType || type < Typelib::ArrayType
                    # ignored
                    return
                end

                result.join("\n")
            end

            def render_project(project)
                puts "rendering #{project.name}"
                package_name = Doc.orogen_to_autoproj[project.name]
                if !package_name
                    STDERR.puts "WARN: cannot find the autoproj package for the oroGen project #{project.name}"
                    return
                end
                project_dir = File.join(output_dir, "packages", Doc.name_to_path(package_name))

                if typekit = project.typekit
                    fragments = []
                    typekit.self_types.to_a.sort_by(&:name).each do |type|
                        fragments << render_type_fragment(type, typekit, 2)
                    end

                    page = <<-EOPAGE
---
title: Types
sort_info: 100
--- name:local_nav
<ul><li class="title">#{package_name}</li>
{menu: {max_levels: 3, start_level: 3, show_current_subtree_only: true, nested: true, used_nodes: files}}
</ul>
--- name:content
#{fragments.compact.join("\n\n")}
                    EOPAGE

                    File.open(File.join(project_dir, "types.page"), 'w') do |io|
                        io.puts page
                    end
                end

                tasks = project.self_tasks
                if !tasks.empty?
                    fragments = []
                    tasks.to_a.sort_by(&:name).each do |task|
                        fragments << render_task_fragment(task, 2)
                    end

                    page = <<-EOPAGE
---
title: Tasks
sort_info: 200
--- name:local_nav
<ul><li class="title">#{package_name}</li>
{menu: {max_levels: 3, start_level: 3, show_current_subtree_only: true, nested: true, used_nodes: files}}
</ul>
--- name:content
#{fragments.join("\n\n")}
                    EOPAGE

                    File.open(File.join(project_dir, "tasks.page"), 'w') do |io|
                        io.puts page
                    end
                end
            end
        end
    end
end

