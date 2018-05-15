require 'rake'

begin
    require 'hoe'
    Hoe::plugin :yard

    Hoe::RUBY_FLAGS.gsub! /-w/, ''

    hoe_spec = Hoe.spec 'apaka' do
        developer 'Thomas Roehr', 'thomas.roehr@dfki.de'
        developer 'Pierre Willenbrock', 'pierre.willenbrock@dfki.de'
        developer 'Sylvain Joyeux', 'sylvain.joyeux@m4x.org'
        self.version = 0.1
        self.summary = "This library provided automated packaging facilities for" \
            "projects managed with autoproj"
        self.description = 'Automated packaging for autoproj'
        self.urls        = ["https://github.com/rock-core/apaka"]
        self.readme_file = FileList['README*'].first
        self.history_file = "History.txt"
        licenses << "LGPL-2.0+"

        extra_deps <<
            ['hoe'] <<
            ['hoe-yard'] <<
            ['rake']
    end

    Rake.clear_tasks(/^default$/)
    task :default => []
    task :docs => :yard
    task :redocs => :yard
rescue LoadError
    STDERR.puts "cannot load the Hoe gem. Distribution is disabled"
rescue Exception => e
    if e.message !~ /\.rubyforge/
        STDERR.puts "WARN: cannot load the Hoe gem, or Hoe fails. Publishing tasks are disabled"
        STDERR.puts "WARN: error message is: #{e.message}"
    end
end
