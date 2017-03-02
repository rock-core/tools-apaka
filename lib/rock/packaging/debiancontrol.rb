

module Autoproj
    module Packaging
        @source = Hash.new
        @packages = Array.new
        
        class DebianControl
            # debian/control file reader/writer
            # These files have the following layout:
            #
            # SourceBlock (having a Source key) 
            # ^\s*$
            # PackageBlock (having a Pacakge key)
            # ^\s*$
            # PackageBlock (having a Pacakge key)
            # ...
            # 
            # There may be signatures interspersed, we don't handle them.
            # Files may be compressed, we don't handle that either.
            # A SourceBlock or PackageBlock is one or more Key/Value pairs as
            # follows:
            #
            # ^<Key>: <Value>
            # ^<Key>: <Value>
            # ^\s<More Value>
            # ...
            # 
            # Result is an array of hashes, preserving the order of the
            # blocks, but not of the key/value pairs.
            #
            def self.parse(source, opts = {})
                blocks = Array.new
                hash = Hash.new
                key = ""
                source.each_line do |line|
                    case line
                    when /^(\S+)\s*:\s*(.*)\s*$/
                        key = $1
                        hash[key] = $2
                    when /^\s(\s*\S.*)$/
                        hash[key] << "\n" + $1
                    when /^\s*$/
                        blocks.push(hash) unless hash.empty?
                        hash = Hash.new
                        key = ""
                    end
                end
                blocks.push(hash) unless hash.empty?
                sourceblock = blocks.shift
                self.new(sourceblock,blocks)
            end #parse
            
            def self.generate(debctl, opts = {})
                ret = ""
                first_block = true
                debctl.blocks.each do |elem|
                    ret << "\n" if ! first_block
                    first_block = false
                    elem.each do |key,value|
                        ret << key << ":"
                        ret << "\n" if value.empty?
                        value.each_line do |line|
                            ret << " " if line !~ /^\s/
                            ret << line
                            ret << "\n" if line !~ /\n$/
                        end
                    end
                end
                ret
            end #generate

            def initialize(source, packages)
                @source = source
                @packages = packages
            end #initialize

            def blocks
                [ @source ] + @packages
            end

            attr_reader :source
            attr_reader :packages
        end #DebianControl
    end
end
