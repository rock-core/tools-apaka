#! /usr/bin/env ruby

require 'rock/gitorious_api.rb'
require 'rexml/document'
require 'fileutils'
require 'pp'
require 'pathname'
require 'fileutils'
# parser = OptionParser.new do |opt|
# end
# remaining = parser.parse(ARGV)

@@target_dir = ARGV[0]

if(!@@target_dir)
    puts("Usage: rock-widget-parser.rb targetDirectory")
    exit
end

# Recursively copy the first directory into the second
FileUtils::cp_r "../resources/widget_parser_template", @@target_dir


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


def write_html(qtwidgets)
    f = File.new(@@target_dir + "/index.html", "w+")

    max_images = 0
    qtwidgets.each do |widget|
        local_count = 0
        widget.images.each do |img|
            local_count = local_count + 1
        end
        max_images = [max_images, local_count].max()
    end

    f.write("
<!DOCTYPE html>
<html>  
  <head>    
    <title>QTWidgets     
    </title>    
    <link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\" media=\"all\">
    <!-- Add jQuery library -->
    <script type=\"text/javascript\" src=\"http://ajax.googleapis.com/ajax/libs/jquery/1.7/jquery.min.js\"></script>
    
    <!-- Add fancyBox -->
    <link rel=\"stylesheet\" href=\"fancybox/jquery.fancybox.css?v=2.1.3\" type=\"text/css\" media=\"screen\" />
    <script type=\"text/javascript\" src=\"fancybox/jquery.fancybox.pack.js?v=2.1.3\"></script>
    
    <!-- Load fancyBox -->    
    <script type=\"text/javascript\">
    	$(document).ready(function() {
    		$(\".fancybox\").fancybox({
  				closeClick : true,
  
  				openEffect : 'elastic',
          closeEffect : 'elastic',
  
  				helpers : {
  					title : {
  						type : 'inside'
  					},
  					overlay : {
  						css : {
  							'background' : 'rgba(238,238,238,0.85)'
  						}
  					}
  				}
  			});
    	});
    </script> 
          
  </head>  
  <body>
    <h1>QTWidgets</h1>    
    <div class=\"widgets\">      
      <table>
")
    qtwidgets.each do |widget|
        f.write("
        <tr>
")
        widget.images.each do |img|
        f.write("
          <td class=\"image\">            
            <a class=\"fancybox\" rel=\"#{widget.name}\" href=\"#{img}\">
              <img src=\"#{img}\">
            </a>
          </td>
")
        end
        
        widget.images.size().upto(max_images -1) do |i|
            f.write("
          <td>            
          </td>
")

        end

        f.write("
          <td>            
            <a href=\"#{widget.url}\">
              <h2>#{widget.name}</h2></a>

              <p><a href=\"#{widget.url}\">URL: #{widget.url}</a></p>
              <p>#{widget.description}</p>
          </td>        
        </tr>      
")
    end
f.write("
      </table>    
    </div>     
  </body>
</html>
")
end

class Hoster
    attr_reader :git_handle
    attr_accessor :projects

    def initialize(url)
        @git_handle = Gitorious.new(url)
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
                        image = git_handle.raw_file_from_git(repo.path, img.text)
                        if(image.include?("Sorry, page not found"))
                            raise
                        end
                        f = File.new(filename, "w+")
                        f.write(image)                        
                        img_paths << Pathname.new(f.path()).relative_path_from(Pathname.new(@@target_dir)) 
                        
                    rescue Exception => e 
                        puts e.message
                        puts("Failed to fetch image #{img.text}")
                    end
                end
                info = QTWidgetInfo.new(name, img_paths, git_handle.repository_url(repo))
                qtwidgets << info
            end
            
            #   pp qtwidgets
        rescue
        end
        qtwidgets
    end

    def getWidgets(filter = nil)
        widgets = Array.new
        projects = git_handle.projects(filter)
        projects.each do |project|
            puts("Project #{project.name}")
            repos = git_handle.gits(project.name)
            repos.each do |repo|
                puts("Repo #{repo.name}")
                manifest_blob = git_handle.raw_file_from_git(repo.path, "manifest.xml")
                if(manifest_blob.include?("Sorry, page not found"))
                    puts("#{repo.name} has no manifest")
                else
                    widgets << parseManifest(repo, manifest_blob)
                    puts("#{repo.name} HAS manifest")
                end
            end
        end        
        return widgets.flatten
    end
end

gitorious = Hoster.new("gitorious.org")
spacegit = Hoster.new("spacegit")

widgets = gitorious.getWidgets("rock-gui")
widgets << spacegit.getWidgets()

widgets.flatten!



write_html(widgets)

