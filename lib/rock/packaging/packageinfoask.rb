
module Autoproj
    module Packaging
        class PackageInfoAsk

            class << self
                alias :class_new :new

                def new(which, options)
                    if which == :detect
                        subclasses.each do |subclass|
                            if subclass.probe
                                return subclass.new(options)
                            end
                        end
                        raise "Cannot find a suitable packageinfo provider"
                    end
                    subclasses.each do |subclass|
                        if which == subclass.which
                            return subclass.new(options)
                        end
                    end
                    raise "Don't know how to create an adaptor for #{which}"
                end

                def inherited(subclass)
                    subclasses.add subclass
                    # this allows child classes to use new as they are used to
                    class << subclass
                        alias :new :class_new
                    end
                end

                def subclasses
                    @subclasses ||= Set.new
                end

                def which
                    raise "#{self} needs to overwrite self.which"
                end

                def probe
                    # default implementation never auto probes
                    false
                end
            end

        end # class PackageInfoAsk
    end # module Packaging
end # module Autoproj

begin
    require 'rock/packaging/autoproj1adaptor'
rescue LoadError
    # in case the adaptors require fails, not so much that this require fails
rescue
    # if one of the backends does not load, we should still be fine.
end
