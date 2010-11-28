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
                return "<a href=\"#{link}\">#{escape_html(type.name)}</a>"
            elsif from == :autoproj_packages
                link = "../#{name_to_path(autoproj_name)}/types.html##{name_to_path(type.name)}"
                return "<a href=\"#{link}\">#{escape_html(type.name)}</a>"
            else
                raise ArgumentError, "#{from} was expected to be one of :orogen_types, :autoproj_packages"
            end
        end

        def self.orogen_task_link(task, from)
            if !(autoproj_name = type_to_autoproj[task.name])
                return escape_html(task.name)
            end

            if from == :orogen_types || from == :orogen_tasks
                link = "../orogen_tasks/#{name_to_path(task.name)}.html"
                return "<a href=\"#{link}\">#{escape_html(task.name)}</a>"
            elsif from == :autoproj_packages
                link = "../#{name_to_path(autoproj_name)}/tasks.html##{name_to_path(task.name)}"
                return "<a href=\"#{link}\">#{escape_html(task.name)}</a>"
            else
                raise ArgumentError, "#{from} was expected to be one of :orogen_types, :autoproj_packages"
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

                all_types, all_tasks = [], []
                all.each do |project|
                    types, tasks = render.render_project(project)
                    all_types.concat(types)
                    all_tasks.concat(tasks)
                end


                sort_order = 0

                types_dir   = File.join(output_dir, "orogen_types")
                FileUtils.mkdir_p(types_dir)
                all_types.sort_by(&:first).each do |type_name, autoproj_name, fragment|
                    page = <<-EOPAGE
---
title: #{type_name}
sort_info: #{sort_order += 1}
---
Defined in the typekit of #{Doc.package_link(autoproj_name, 1)}

#{fragment}
                    EOPAGE

                    Doc.render_page(File.join(types_dir, "#{Doc.name_to_path(type_name)}.page"), page)
                end

                tasks_dir   = File.join(output_dir, "orogen_tasks")
                FileUtils.mkdir_p(tasks_dir)
                all_tasks.sort_by(&:first).each do |task_name, autoproj_name, fragment|
                    page = <<-EOPAGE
---
title: #{task_name}
sort_info: #{sort_order += 1}
---
Defined in the task library of #{Doc.package_link(autoproj_name, 1)}

#{fragment}
                    EOPAGE

                    Doc.render_page(File.join(tasks_dir, "#{Doc.name_to_path(task_name)}.page"), page)
                end
            end

            attr_reader :output_dir
            def initialize(output_dir)
                @output_dir = output_dir
                @sort_order = 0
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
                    render_type_definition_fragment(result, type, from)

                    if type.contains_opaques?
                        intermediate = typekit.intermediate_type_for(type)
                        result << "" << "contains opaque types, and is therefore marshalled as #{intermediate.name}"
                        render_type_definition_fragment(result, intermediate, from)
                    end

                elsif type < Typelib::OpaqueType
                    intermediate = typekit.intermediate_type_for(type)
                    result << ""
                    result << "is an opaque type which is marshalled as #{Doc.orogen_type_link(intermediate, from)}"

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
                project_dir = File.join(output_dir, "packages", Doc.name_to_path(package_name))

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
                        all_types << [type.name, package_name, fragment]
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
                        all_tasks << [task.name, package_name, fragment]
                    end
                end

                return all_types, all_tasks
            end
        end
    end
end

