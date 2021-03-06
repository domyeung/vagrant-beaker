module VagrantPlugins
  module Beaker
    module Provider
      module VSphereActions
        class CloneTemplate
          def initialize( app, env )
            @app = app
            @logger = Log4r::Logger.new( 'vagrant_plugins::beaker::provider::vsphere_actions::clone_template' )
          end

          def call( env )

            ui         = env[:machine].ui
            config     = env[:machine].provider_config

            vsphere    = env[:vsphere][:connection]
            connection = vsphere.instance_variable_get :@connection
            datacenter = connection.serviceInstance.find_datacenter

            remote = find_and_validate_objects!( config, vsphere, ui )

            username = real_username( config.username )

            vmname, vmpath = nil, nil
            loop do
              vmname = vmname_for( username )
              vmpath = [config.target_folder, vmname].join( '/' )
              break unless datacenter.find_vm( vmpath )
            end

            ui.info 'Provisioning vm at: ' + vmpath
            ui.report_progress 0, 100

            task = clone( vsphere:       vsphere,
                          resource_pool: remote[:resource_pool],
                          datastore:     remote[:datastore],
                          folder:        remote[:folder],
                          template:      remote[:template],
                          name:          vmname                   )

            wait_for task, connection, ui

            vm = datacenter.find_vm( config.target_folder + '/' + vmname )

            metadata = {
              'machine_name' =>  vmname,
              'state'        => 'deployed-off',
              'mo_ref'       =>  vm._ref,
              'vagrant_ref'  =>  env[:root_path].to_s + '/Vagrantfile/' + env[:machine].name.to_s,
              'id'           =>  vm.config.instanceUuid,
              'created_on'   =>  Time.now.getutc,
              'created_by'   =>  config.username
            }

            vm.ReconfigVM_Task( spec: { annotation: metadata.to_json })

            metadata_file = File.join( env[:machine].data_dir.to_s, 'metadata.json' )
            File.open( metadata_file, 'w+' ) {|f| f.write( metadata.to_json ) }

            env[:vsphere][:metadata] = metadata

            ui.clear_line
            ui.report_progress 100, 100
            ui.info "\nCompleted clone"


            @app.call( env )
          end

          def find_and_validate_objects!( config, vsphere, ui )
            ui.info 'Validating existence of Resource Pool: ' + config.target_resource_pool
            resource_pool, pool_error  = carefully_find type: 'Resource Pool',
                                                        named: config.target_resource_pool,
                                                        with: vsphere.method( :find_pool )

            ui.info 'Validating existence of Datastore: ' + config.target_datastore
            datastore, store_error = carefully_find type: 'Datastore',
                                                    named: config.target_datastore,
                                                    with: vsphere.method( :find_datastore )

            ui.info 'Validating existence of Target Folder: ' + config.target_folder
            folder, folder_error = carefully_find type: 'Target Folder',
                                                  named: config.target_folder,
                                                  with: vsphere.method( :find_folder )

            connection = vsphere.instance_variable_get :@connection
            ui.info 'Validating existence of Template: ' + config.template
            template = connection.serviceInstance.find_datacenter.find_vm( config.template )
            template_error = template ? nil : ['Template', config.template]

            errors = [ pool_error, store_error, folder_error, template_error ].compact

            unless errors.empty?
              raise "There were errors when finding:\n" +
                      errors.map {|e| e[0] + ': ' + e[1] }.join("\n")
            end

            return { resource_pool: resource_pool,
                     datastore:     datastore,
                     folder:        folder,
                     template:      template        }
          end

          def carefully_find( args )
            value, errors = nil, nil

            begin
              value = args[:with].call( args[:named] )
            rescue SystemExit => e
              errors = [ args[:type], args[:named] ]
            end

            return [ value, errors ]
          end

          def vmname_for( username )
            random = rand( 100...1000 )
            username + '-' + random.to_s
          end

          def real_username( username )
            username_without_dn = username.split('@')[0]

            if username_without_dn =~ /\./
              first_name, last_name = username_without_dn.split('.')
              user = first_name[0..10] + last_name[0..1]
            else
              user = username_without_dn[0..11]
            end

            user
          end

          def clone( args )
            relocate_spec = RbVmomi::VIM.VirtualMachineRelocateSpec(
              datastore:     args[:datastore],
              pool:          args[:resource_pool],
              diskMoveType: :moveChildMostDiskBacking
            )

            custom_spec = args[:vsphere].find_customization( path_for( args[:template] ) )

            spec = RbVmomi::VIM.VirtualMachineCloneSpec(
              config:        {},
              location:      relocate_spec,
              customization: custom_spec,
              powerOn:       false,
              template:      false
            )

            clone_task = args[:template].CloneVM_Task( name:   args[:name],
                                                       spec:   spec,
                                                       folder: args[:folder] )

            return clone_task
          end

          def path_for( object )
            index = object.path.index( object.path.rassoc( 'vm' ) ) + 1
            object.path.drop( index ).map( &:last ).join( '/' )
          end

          def wait_for task, connection, ui
            filter = connection.propertyCollector.CreateFilter(
              spec: {
                propSet: [{
                           type:      'Task',
                           all:        false,
                           pathSet: [ 'info.state',
                                      'info.progress' ]
                         }],
                objectSet: [{ obj: task }]
              },
              partialUpdates: false
            )

            # yeah, it's a really long name, but not as long as it took my
            # simple brain to figure out what the hell it was
            last_point_in_update_stream = ''
            polling = true

            # block until our tasks have succeeded or errored
            loop do
              result = connection.propertyCollector.WaitForUpdates(
                :version => last_point_in_update_stream
              )

              last_point_in_update_stream = result.version

              if ['success', 'error'].member? task.info.state
                break
              else
                ui.clear_line
                ui.report_progress task.info.progress, 100
              end
            end

            filter.DestroyPropertyFilter

            # fail if we weren't successful
            raise 'Failed to clone VM' if task.info.state == 'error'
          end
        end
      end
    end
  end
end
