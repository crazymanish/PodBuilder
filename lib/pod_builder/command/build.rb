require 'pod_builder/core'

module PodBuilder
  module Command
    class Build
      def self.call(options)          
        Configuration.check_inited
        PodBuilder::prepare_basepath

        argument_pods = ARGV.dup

        unless argument_pods.count > 0 
          return -1
        end

        raise "\n\nPlease rename your Xcode installation path removing spaces, current `#{`xcode-select -p`.strip()}`\n" if `xcode-select -p`.strip().include?(" ")

        Podfile.sanity_check()
        check_not_building_subspecs(argument_pods)

        install_update_repo = options.fetch(:update_repos, true)
        installer, analyzer = Analyze.installer_at(PodBuilder::basepath, install_update_repo)

        all_buildable_items = Analyze.podfile_items(installer, analyzer)
        prebuilt_items = all_buildable_items.select { |x| x.is_prebuilt }
        buildable_items = all_buildable_items - prebuilt_items

        if argument_pods.first == "*"
          argument_pods = buildable_items.map(&:root_name)
        end

        available_argument_pods = argument_pods.select { |x| all_buildable_items.map(&:root_name).include?(x) }     
        (argument_pods - available_argument_pods).each { |x|
          puts "'#{x}' not found, skipping".magenta
        }
        argument_pods = available_argument_pods.uniq
        
        prebuilt_pods_to_install = prebuilt_items.select { |x| argument_pods.include?(x.root_name) }

        Podfile.restore_podfile_clean(all_buildable_items)

        restore_file_error = Podfile.restore_file_sanity_check
  
        check_splitted_subspecs_are_static(all_buildable_items, options)
        check_pods_exists(argument_pods, all_buildable_items)

        pods_to_build = resolve_pods_to_build(argument_pods, buildable_items, options)
        buildable_items -= pods_to_build

        # We need to split pods to build in 3 groups
        # 1. subspecs: because the resulting .framework path is treated differently when added to Configuration.subspecs_to_split
        # 2. pods to build in release
        # 3. pods to build in debug

        check_not_building_development_pods(pods_to_build, options)

        pods_to_build_subspecs = pods_to_build.select { |x| x.is_subspec && Configuration.subspecs_to_split.include?(x.name) }

        # Remove dependencies from pods to build
        all_dependencies_name = pods_to_build.map(&:dependency_names).flatten.uniq
        pods_to_build.select! { |x| !all_dependencies_name.include?(x.name) }

        pods_to_build -= pods_to_build_subspecs
        pods_to_build_debug = pods_to_build.select { |x| x.build_configuration == "debug" }
        pods_to_build_release = pods_to_build - pods_to_build_debug

        check_dependencies_build_configurations(all_buildable_items)

        podfiles_items = pods_to_build_subspecs.map { |x| [x] }
        podfiles_items.push(pods_to_build_debug)
        podfiles_items.push(pods_to_build_release)   

        licenses = []
        
        podfiles_items.select { |x| x.count > 0 }.each do |podfile_items|
          podfile_items = add_dependencies(podfile_items, all_buildable_items)
          podfile_content = Podfile.from_podfile_items(podfile_items, analyzer)
          
          Install.podfile(podfile_content, podfile_items, podfile_items.first.build_configuration)

          licenses += license_specifiers
          
          # remove lockfile which gets unexplicably created
          FileUtils.rm_f(PodBuilder::basepath("Podfile.lock"))
        end

        clean_frameworks_folder(all_buildable_items)

        Licenses::write(licenses, all_buildable_items)

        GenerateLFS::call(nil)
        Podspec::generate(all_buildable_items, analyzer)

        builded_pods = podfiles_items.flatten
        builded_pods_and_deps = add_dependencies(builded_pods, all_buildable_items).select { |x| !x.is_prebuilt }
        Podfile::write_restorable(builded_pods_and_deps + prebuilt_pods_to_install, all_buildable_items, analyzer)     
        if !options.has_key?(:skip_prebuild_update)   
          Podfile::write_prebuilt(all_buildable_items, analyzer)
        end

        Podfile::install

        sanity_checks(options)

        if (restore_file_error = restore_file_error) && Configuration.restore_enabled
          puts "\n\n⚠️ Podfile.restore was found invalid and was overwritten. Error:\n #{restore_file_error}".red
        end

        puts "\n\n🎉 done!\n".green
        return 0
      end

      private

      def self.license_specifiers
        acknowledge_files = Dir.glob("#{PodBuilder::Configuration.build_path}/Pods/**/*acknowledgements.plist")
        raise "Too many ackwnoledge files found" if acknowledge_files.count > 1

        if acknowledge_file = acknowledge_files.first
          plist = CFPropertyList::List.new(:file => acknowledge_file)
          data = CFPropertyList.native_types(plist.value)
          
          return data["PreferenceSpecifiers"]
        end

        return []
      end

      def self.add_dependencies(pods, buildable_items)
        pods.dup.each do |pod|
          build_configuration = pods.first.build_configuration

          dependencies = pod.dependencies(buildable_items).select { |x| !pods.include?(x) && !pod.has_common_spec(x.name) }
          dependencies.each { |x| x.build_configuration = build_configuration }
          pods = dependencies + pods # dependencies should come first
        end
        
        return pods
      end

      def self.expected_common_dependencies(pods_to_build, buildable_items, options)
        warned_expected_pod_list = []
        expected_pod_list = []
        errors = []

        pods_to_build.each do |pod_to_build|
          pod_to_build.dependency_names.each do |dependency|
            unless buildable_items.detect { |x| x.root_name == dependency || x.name == dependency } != nil
              next
            end

            buildable_items.each do |buildable_pod|
              unless !pod_to_build.dependency_names.include?(buildable_pod.name)
                next
              end

              if buildable_pod.dependency_names.include?(dependency) && !buildable_pod.has_subspec(dependency) && !buildable_pod.has_common_spec(dependency) then
                expected_pod_list += pods_to_build.map(&:root_name) + [buildable_pod.root_name]
                expected_pod_list.uniq!

                expected_list = expected_pod_list.join(" ")
                if !warned_expected_pod_list.include?(expected_list)
                  errors.push("Can't build #{pod_to_build.name} because it has common dependencies (#{dependency}) with #{buildable_pod.name}.\n\nUse `pod_builder build #{expected_list}` instead or use `pod_builder build -a #{pod_to_build.name}` to automatically resolve missing dependencies\n\n")
                  errors.uniq!
                  warned_expected_pod_list.push(expected_list)

                  if options.has_key?(:auto_resolve_dependencies)
                    puts "`#{pod_to_build.name}` has the following dependencies:\n`#{pod_to_build.dependency_names.join("`, `")}`\nWhich are in common with `#{buildable_pod.name}` and requires it to be recompiled\n\n".yellow
                  end
                end
              end
            end
          end
        end

        return expected_pod_list, errors
      end

      def self.expected_parent_dependencies(pods_to_build, buildable_items, options)
        expected_pod_list = []
        errors = []

        buildable_items_dependencies = buildable_items.map(&:dependency_names).flatten.uniq
        pods_to_build.each do |pod_to_build|
          if buildable_items_dependencies.include?(pod_to_build.name)
            parent = buildable_items.detect { |x| x.dependency_names.include?(pod_to_build.name) }

            expected_pod_list += (pods_to_build + [parent]).map(&:root_name)
            expected_pod_list.uniq!
            errors.push("Can't build #{pod_to_build.name} because it is a dependency of #{parent.name}.\n\nUse `pod_builder build #{expected_pod_list.join(" ")}` instead\n\n")
          end
        end

        return expected_pod_list, errors
      end

      def self.check_not_building_subspecs(pods_to_build)
        pods_to_build.each do |pod_to_build|
          if pod_to_build.include?("/")
            raise "\n\nCan't build subspec #{pod_to_build} refer to podspec name.\n\nUse `pod_builder build #{pods_to_build.map { |x| x.split("/").first }.uniq.join(" ")}` instead\n\n".red
          end
        end
      end

      def self.check_pods_exists(pods, buildable_items)
        raise "Empty Podfile?" if buildable_items.nil?

        buildable_items = buildable_items.map(&:root_name)
        pods.each do |pod|
          raise "\n\nPod `#{pod}` wasn't found in Podfile.\n\nFound:\n#{buildable_items.join("\n")}\n\n".red if !buildable_items.include?(pod)
        end
      end

      def self.check_splitted_subspecs_are_static(all_buildable_items, options)
        non_static_subspecs = all_buildable_items.select { |x| x.is_subspec && x.is_static == false }
        non_static_subspecs_names = non_static_subspecs.map(&:name)

        invalid_subspecs = Configuration.subspecs_to_split & non_static_subspecs_names # intersect

        unless invalid_subspecs.count > 0
          return
        end

        warn_message = "The following pods `#{invalid_subspecs.join(" ")}` are non static frameworks which are being splitted over different targets. Beware that this is an unsafe setup as per https://github.com/CocoaPods/CocoaPods/issues/5708 and https://github.com/CocoaPods/CocoaPods/issues/5643\n\nYou can ignore this error by passing the `--allow-warnings` flag to the build command\n"
        if options[:allow_warnings]
          puts "\n\n⚠️  #{warn_message}".yellow
        else
          raise "\n\n🚨️  #{warn_message}".yellow
        end
      end

      def self.check_dependencies_build_configurations(pods)
        pods.each do |pod|
          pod_dependency_names = pod.dependency_names.select { |x| !pod.has_common_spec(x) }

          remaining_pods = pods - [pod]
          pods_with_common_deps = remaining_pods.select { |x| x.dependency_names.any? { |y| pod_dependency_names.include?(y) && !x.has_common_spec(y) } }
          
          pods_with_unaligned_build_configuration = pods_with_common_deps.select { |x| x.build_configuration != pod.build_configuration }
          pods_with_unaligned_build_configuration.map!(&:name)

          raise "Dependencies of `#{pod.name}` don't have the same build configuration (#{pod.build_configuration}) of `#{pods_with_unaligned_build_configuration.join(",")}`'s dependencies" if pods_with_unaligned_build_configuration.count > 0
        end
      end

      def self.check_not_building_development_pods(pods, options)
        if (development_pods = pods.select { |x| x.is_development_pod }) && development_pods.count > 0 && (options[:allow_warnings].nil?  && Configuration.allow_building_development_pods == false)
          pod_names = development_pods.map(&:name).join(", ")
          raise "The following pods are in development mode: `#{pod_names}`, won't proceed building.\n\nYou can ignore this error by passing the `--allow-warnings` flag to the build command\n"
        end
      end

      def self.other_subspecs(pods_to_build, buildable_items)
        buildable_subspecs = buildable_items.select { |x| x.is_subspec }
        pods_to_build_subspecs = pods_to_build.select { |x| x.is_subspec }.map(&:root_name)

        buildable_subspecs.select! { |x| pods_to_build_subspecs.include?(x.root_name) }

        return buildable_subspecs - pods_to_build
      end

      def self.sanity_checks(options)
        lines = File.read(PodBuilder::project_path("Podfile")).split("\n")
        stripped_lines = lines.map { |x| Podfile.strip_line(x) }.select { |x| !x.start_with?("#")}

        expected_stripped = Podfile::POST_INSTALL_ACTIONS.map { |x| Podfile.strip_line(x) }

        if !expected_stripped.all? { |x| stripped_lines.include?(x) }
          warn_message = "PodBuilder's post install actions missing from application Podfile!\n"
          if options[:allow_warnings]
            puts "\n\n⚠️  #{warn_message}".yellow
          else
            raise "\n\n🚨️  #{warn_message}".red
          end
        end
      end

      def self.resolve_pods_to_build(argument_pods, buildable_items, options)
        pods_to_build = []
        
        fns = [method(:expected_common_dependencies), method(:expected_parent_dependencies)]
        fns.each do |fn|
          loop do
            pods_to_build = buildable_items.select { |x| argument_pods.include?(x.root_name) }
            pods_to_build += other_subspecs(pods_to_build, buildable_items)
            tmp_buildable_items = buildable_items - pods_to_build

            expected_pods, errors = fn.call(pods_to_build, tmp_buildable_items, options)
            if expected_pods.count > 0
              if !options.has_key?(:auto_resolve_dependencies) && expected_pods.count > 0
                raise "\n\n#{errors.join("\n")}".red
              else
                argument_pods = expected_pods.uniq
              end  
            end
            
            if !options.has_key?(:auto_resolve_dependencies) || expected_pods.count == 0
              break
            end
          end  
        end

        return pods_to_build
      end

      def self.clean_frameworks_folder(buildable_items)
        puts "Cleaning framework folder".yellow

        expected_frameworks = buildable_items.map { |x| "#{x.module_name}.framework" }
        expected_frameworks += buildable_items.map { |x| x.vendored_items }.flatten.map { |x| File.basename(x) }
        expected_frameworks.uniq!

        existing_frameworks = Dir.glob("#{PodBuilder::basepath("Rome")}/*.framework")

        existing_frameworks.each do |existing_framework|
          existing_framework_name = File.basename(existing_framework)
          if !expected_frameworks.include?(existing_framework_name)
            puts "Cleanining up `#{existing_framework_name}`, no longer found among dependencies".blue
            FileUtils.rm_rf(existing_framework)
          end
        end

        existing_dsyms = Dir.glob("#{PodBuilder::basepath("dSYM")}/**/*.dSYM")
        existing_dsyms.each do |existing_dsym|
          existing_dsym_name = File.basename(existing_dsym)
          if !expected_frameworks.include?(existing_dsym_name.gsub(".dSYM", ""))
            puts "Cleanining up `#{existing_dsym_name}`, no longer found among dependencies".blue
            FileUtils.rm_rf(existing_dsym)
          end
        end
      end
    end
  end
end
