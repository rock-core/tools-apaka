#! /usr/bin/env ruby

require 'rock/gitorious_api.rb'
require 'rexml/document'
require 'fileutils'
require 'pp'

@@git = Gitorious.new("spacegit")
@@target_dir = './'

projects = @@git.projects()

class QTWidgetInfo
    attr_reader :name
    attr_reader :description
    attr_reader :short_description
    attr_reader :images
    attr_reader :url

    def initialize(name, images, url)
        @name = name
        @images = images
        @url = url
    end
end

def parseManifest(repo, manifest) 
    qtwidgets = []
    begin
    # extract event information
    doc = REXML::Document.new(manifest)

    doc.elements.each('package/qtwidget') do |ele|
        name = ele.attributes["name"]
        img_paths = []
        ele.elements.each('image') do |img|
            begin
            filename = @@target_dir + repo.path + "/"+ img.text
            FileUtils.mkdir_p(File.dirname(filename))
            image = @@git.raw_file_from_git(repo.path, img.text)
            if(image.include?("Sorry, page not found"))
                raise
            end
            f = File.new(filename, "w+")
            f.write(image)
            img_paths << filename
                
            rescue
                puts("Failed to fetch image #{img.text}")
            end
        end

        info = QTWidgetInfo.new(name, img_paths, @@git.repository_url(repo))
        qtwidgets << info
    end

 #   pp qtwidgets
    rescue
    end
    qtwidgets
end

def write_html(qtwidgets)
    f = File.new(@@target_dir + "index.html", "w+")

    f.write("<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01//EN\"
       \"http://www.w3.org/TR/html4/strict.dtd\">
<html>
<head>
<title>QTWidgets</title>
</head>
<body>

<h1>QTWidgets</h1>")

    qtwidgets.each do |widget|
        f.write("<a href=\"#{widget.url}\"><h1>#{widget.name}</h1></a>")
        
        widget.images.each do |img|
        f.write("<p><img src=\"#{img} \"></p>")
end
end

f.write("</body>
</html>")

end

widgets = []
projects.each do |project|
#    puts("Project #{project.name}")
    repos = @@git.gits(project.name)
    repos.each do |repo|
#        puts("Repo #{repo.name}")
        manifest_blob = @@git.raw_file_from_git(repo.path, "manifest.xml")
        if(manifest_blob.include?("Sorry, page not found"))
#            puts("#{repo.name} has no manifest")
        else
            widgets << parseManifest(repo, manifest_blob)
#            puts("#{repo.name} HAS manifest")
        end
    end
end
widgets.flatten!
write_html(widgets)

