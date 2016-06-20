require 'rake'

begin
    require 'hoe'
    Hoe::plugin :yard

    Hoe::RUBY_FLAGS.gsub! /-w/, ''

    hoe_spec = Hoe.spec 'admin_scripts' do
        developer 'Sylvain Joyeux', 'sylvain.joyeux@m4x.org'
        developer 'Thomas Roehr', 'thomas.roehr@dfki.de'
        self.version = 0.1
        self.description = 'General scripts for administration of a Rock installation'
        self.urls        = ["https://github.com/rock-core/base-admin_scripts"]
        self.readme_file = FileList['README*'].first
        self.history_file = "History.txt"
        licenses << 'GPLv2+'

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
