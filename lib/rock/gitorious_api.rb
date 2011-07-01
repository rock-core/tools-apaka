require 'net/http'
require 'uri'
require 'yaml'

class Gitorious
    attr_accessor :hostname

    def initialize(hostname)
        @hostname = hostname
    end

    def http_uri
        "http://#{hostname}/"
    end

    #returns all projects which are hosted at @http_uri
    def projects(filter=nil)
        array = Array.new
        body = raw_file(http_uri+'/projects')
        reg = Regexp.new(filter) if filter
        body.scan(/<h3><a href="(.*)">(.*)<\/a><\/h3>/) do |path,name|
            if reg
                array << NamePath.new(name,path) if name.match(reg)
            else
                array << NamePath.new(name,path)
            end
        end
        return array
    end

    #returns all gits which are hosted at @http_uri/project
    def gits(project)
        array = Array.new
        body = raw_file(http_uri+project)
        body.scan(/<h3 mainline>.*\n.*<a href="(.*)">(.*)<\/a>/) do |path,name|
            array << NamePath.new(name,path)
        end
        return array
    end

    #returns true if the project has a git with the given name
    def git?(project_path,git_name)
        result = gits(project_path)
        result.find do |x|
            x.name.to_s == git_name
        end
    end

    #return the branches of the git
    def git_branches(git)
        array = Array.new
        body = raw_file(http_uri + git)
        body.scan(/" title=".*>(.*)<\/a><\/li>/) do |branch|
            array << branch
        end
        array.flatten
    end

    #returns the raw file from git and branch 
    def raw_file_from_git(git,file,branch ='master')
        path = http_uri + git + "/blobs/raw/#{branch}/" + file
        raw_file(path)
    end

    #returns the raw file from http address 
    def raw_file(path)
        puts path
        url = URI.parse(path)
        res = Net::HTTP.get_response(url)
        return res.body
    end

    #returns a list of all root files
    def dir_git(git,branch='master',reg=nil)
        path = http_uri + git + '/trees/master' 
        raw = raw_file(path)
        # find all files
        array = Array.new
        reg = Regexp.new(reg) if reg.is_a?(String)
        raw.scan(/file.*\n.*<a href="\/.*>(.*)<\/a>.*<\/td>/) do |name|
            if reg
                array << name.to_s if name.to_s.match(reg)
            else  
                array << name.to_s
            end
        end
        return array
    end

    #returns the name of the package set which is set in source.yml
    def package_set_name(path, branch='master')
        file = dir_git(path,branch,/source\.yml/)
        raw  = raw_file_from_git(path,file[0])
        yaml = YAML.load(raw)
        yaml["name"]
    end

    #asks the user to choose on of namepath
    def ask_for(message,array_of_namepath)
        result = choose do |menu|
            menu.prompt = message
            array_of_namepath.each do |x|
                menu.choice x.name.to_sym
            end
        end
        array_of_namepath.find {|x| x.name==result.to_s}
    end

    #asks the user to choose on of namepath
    def ask_for_item(message,array)
        result = choose do |menu|
            menu.prompt = message
            array.each do |x|
                menu.choice x.to_sym
            end
        end
        result.to_s
    end

    #asks user to select a package set
    def ask_for_package_set(message)
        ask_for(message,package_sets)
    end

    #asks user to select brnach
    def ask_for_branch(git,message)
        branch = git_branches(git)
        return branch[0] if branch.size == 1
        ask_for_item(message,branch)
    end

    #asks user to select a project
    def ask_for_project(message)
        ask_for(message,projects)
    end

    #check for authonticatin
    def log_in?(user_name, password)
        url = URI.parse(http_uri+'/')
        req = Net::HTTP::Post.new(url.path)
        req.basic_auth user_name , password
        res = Net::HTTP.new(url.host, url.port).start{|http| http.request(req)}
        case res
        when Net::HTTPSuccess , Net::HTTPRedirection
            if nil != res.body.match(/Logout/)
                return 1
            else
                return 0
            end
        else
            res.error!
            return 2
        end 
    end

    #check for authorization
    def authorization?(project,user_name, password)
        url = URI.parse(http_uri+project)
        req = Net::HTTP::Get.new(url.path)
        req.basic_auth user_name, password
        res = Net::HTTP.new(url.host, url.port).start{|http| http.request(req)}
        case res
        when Net::HTTPSuccess , Net::HTTPRedirection
            if nil != res.body.match(/edit/)
                return 1
            else
                return 0
            end
        end 
    end

    #creates a new git at @http_uri/project
    def create_git(project,git_name,description,user_name,password)
        url = URI.parse(http_uri+project+'/repositories')
        req = Net::HTTP::Post.new(url.path)
        req.basic_auth user_name, password
        req.set_form_data({'repository[name]'=> git_name, 'repository[description]'=>description,
                       'repository[merge_requests_enabled]'=> 1}, ';')
        res = Net::HTTP.new(url.host, url.port).start do |http|
            http.request(req) 
        end
        case res
        when Net::HTTPSuccess, Net::HTTPRedirection
            return 0 if nil == res.body.match(/redirected/)
            sleep 5
        else
            return 0
        end
        return 1
    end

    NamePath = Struct.new(:name,:path)
end
