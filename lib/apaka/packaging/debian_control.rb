module Apaka
    module Packaging
        class DebianControl
            attr_reader :source
            attr_reader :packages

            @source = Hash.new
            @packages = Array.new

            # https://www.debian.org/doc/debian-policy/ch-controlfields.html
            #
            # debian/control file reader/writer
            # These files have the following layout:
            #
            # SourceParagraph (having a Source key)
            # ^\s*$
            # PackageParagraph (having a Package key)
            # ^\s*$
            # PackageParagraph (having a Packge key)
            # ...
            #
            # There may be signatures interspersed, we don't handle them.
            # Files may be compressed, we don't handle that either.
            # A SourceParagraph or PackageParagraph is one or more Key/Value pairs as
            # follows:
            #
            # ^<Key>: <Value>
            # ^<Key>: <Value>
            # ^\s<More Value>
            # ...
            #
            # Result is an array of hashes, preserving the order of the
            # paragraphs, but not of the key/value pairs.
            #
            def self.load(filename, opts = {})
                paragraphs = Array.new
                hash = Hash.new
                key = ""
                File.open(filename).each_line do |line|
                    case line
                    when /^(\S+)\s*:\s*(.*)\s*$/
                        key = $1
                        hash[key] = $2
                    when /^\s(\s*\S.*)$/
                        hash[key] << "\n" + $1
                    when /^\s*$/
                        paragraphs.push(hash) unless hash.empty?
                        hash = Hash.new
                        key = ""
                    end
                end
                paragraphs.push(hash) unless hash.empty?
                sourceparagraph = paragraphs.shift
                self.new(sourceparagraph,paragraphs)
            end #parse

            def self.generate(debctl, opts = {})
                ret = ""
                first_paragraph = true
                debctl.paragraphs.each do |elem|
                    ret << "\n" if ! first_paragraph
                    first_paragraph = false
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

            def paragraphs
                [ @source ] + @packages
            end

            # Save the debian control file
            def save(filename)
                File.write(filename, DebianControl.generate(self))
            end
        end #DebianControl
    end
end
