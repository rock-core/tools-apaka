module Apaka
    module Packaging
        class OBS
            @@obs_cmd = "osc"

            def self.obs_cmd
                @@obs_cmd
            end

            # Update the open build local checkout
            # using a given checkout directory and the pkg name
            # use a specific file pattern to set allowed files
            # source directory
            # obs_dir target obs checkout directory
            # src_dir where the source dir is
            # pkg_name
            # allowed file patterns
            def self.update_dir(obs_dir, src_dir, pkg_obs_name, file_suffix_patterns = ".*", commit = true)
                pkg_obs_dir = File.join(obs_dir, pkg_obs_name)
                if !File.directory?(pkg_obs_dir)
                    FileUtils.mkdir_p pkg_obs_dir
                    system("#{obs_cmd} add #{pkg_obs_dir}")
                end

                # sync the directory in build/obs and the target directory based on an existing
                # files pattern
                files = []
                file_suffix_patterns.map do |p|
                    # Finding files that exist in the source directory
                    # needs to handle ruby-hoe_0.20130113/*.dsc vs. ruby-hoe-yard_0.20130113/*.dsc
                    # and ruby-hoe/_service
                    glob_exp = File.join(src_dir,pkg_obs_name,"*#{p}")
                    files += Dir.glob(glob_exp)
                end
                files = files.flatten.uniq
                Packager.debug "update directory: files in src #{files}"

                # prepare pattern for target directory
                expected_files = files.map do |f|
                    File.join(pkg_obs_dir, File.basename(f))
                end
                Packager.debug "target directory: expected files: #{expected_files}"

                existing_files = Dir.glob(File.join(pkg_obs_dir,"*"))
                Packager.debug "target directory: existing files: #{existing_files}"

                existing_files.each do |existing_path|
                    if not expected_files.include?(existing_path)
                        Packager.warn "OBS: deleting #{existing_path} -- not present in the current packaging"
                        FileUtils.rm_f existing_path
                        system("#{obs_cmd} rm #{existing_path}")
                    end
                end

                # Add the new unchanged files
                files.each do |path|
                    target_file = File.join(pkg_obs_dir, File.basename(path))
                    exists = File.exist?(target_file)
                    if exists
                        if File.read(path) == File.read(target_file)
                            Packager.info "OBS: #{target_file} is unchanged, skipping"
                        else
                            Packager.info "OBS: #{target_file} updated"
                            FileUtils.cp path, target_file
                        end
                    else
                        FileUtils.cp path, target_file
                        system("#{obs_cmd} add #{target_file}")
                    end
                end

                if commit
                    Packager.info "OBS: committing #{pkg_obs_dir}"
                    system("#{obs_cmd} ci #{pkg_obs_dir} -m \"autopackaged using autoproj-packaging tools\"")
                else
                    Packager.info "OBS: not commiting #{pkg_obs_dir}"
                end
            end

            # List the existing package in the projects
            # The list will contain only the name, suffix '.deb' has
            # been removed
            def self.list_packages(project, repository, architecture = "i586")
                result = %x[#{obs_cmd} ls -b -r #{repository} -a #{architecture} #{project}].split("\n")
                pkg_list = result.collect { |pkg| pkg.sub(/(_.*)?.deb/,"") }
                pkg_list
            end
        end # Obs
    end # Packaging
end # Autoproj

