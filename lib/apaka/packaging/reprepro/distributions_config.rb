require_relative 'release_config' 

module Apaka
    module Packaging
        module Reprepro
            class DistributionsConfig
                attr_reader :releases

                def initialize
                    @releases = Hash.new
                end

                def self.load(filename)
                    dc = DistributionsConfig.new
                    rc = nil
                    File.open(filename).each_line do |line|
                        case line
                        when /Codename:(.*)/
                            if rc
                                dc.releases[rc.codename] = rc
                            end
                            rc = ReleaseConfig.new
                            rc.codename = $1.strip()
                        when /^Description:(.*)/
                            rc.description = $1.strip()
                        when /^Architectures:(.*)/
                            rc.architectures = $1.strip().split(" ")
                        when /^SignWith:(.*)/
                            rc.sign_with = $1.strip()
                        when /^UDebComponents:(.*)/
                            rc.udeb_components = $1.strip()
                        when /^Components:(.*)/
                            rc.components = $1.strip()
                        when /^Tracking:(.*)/
                            rc.tracking = $1.strip()
                        when /^Contents:(.*)/
                            rc.contents = $1.strip()
                        end
                    end
                    if rc
                        dc.releases[rc.codename] = rc
                    end
                    dc
                end

                def to_s
                    s = ""
                    @releases.each do |codename, release|
                        s += release.to_s
                        s += "\n"
                    end
                    s
                end

                # Save the config file
                def save(filename)
                    File.write(filename, self.to_s)
                end
            end
        end
    end
end
