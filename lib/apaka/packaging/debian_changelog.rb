module Apaka
    module Packaging
        class DebianChangelog
            attr_accessor :name
            attr_accessor :version
            attr_accessor :distribution
            attr_accessor :urgency

            # Array containing the changelog entries
            attr_accessor :body

            attr_accessor :maintainer_name
            attr_accessor :maintainer_email
            attr_accessor :date

            def save(filename)
                File.open(filename,"w") do |file|
                    file.write "#{name} (#{version}) #{distribution}; urgency=#{urgency}\n"
                    file.write "\n"
                    body.each do |line|
                        file.write "  * #{line}\n"
                    end
                    file.write "\n"
                    file.write " -- #{maintainer_name} <#{maintainer_email}>  #{date}\n"
                end
            end

            def initialize(filename)
                @body = Array.new
                if not File.exist?(filename)
                    raise RuntimeError, "Apaka::Packaging::DebianChangelog: #{filename} does not exist"
                end
                File.open(filename,"r").each_line do |line|
                    if line =~ /(.*) \((.*)\) (.*); urgency=(.*)/
                       @name = $1
                       @version = $2
                       @distribution = $3
                       @urgency = $4
                    elsif line =~ / -- (.*) <(.*)>  (.*)/
                        @maintainer_name = $1
                        @maintainer_email = $2
                        @date = $3
                    elsif line =~ /  \* (.*)/
                        @body << $1
                    end
                end
            end #initialize
        end #DebianChangelog
    end
end
