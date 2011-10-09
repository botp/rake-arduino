require 'rake/arduino/core_ext/pathname'

module Rake
  module Arduino
    class Sketch
      include Rake::DSL

      attr_accessor :main
      attr_accessor :board
      attr_accessor :libraries
      attr_accessor :hex, :elf
      attr_accessor :programmer, :upload_rate
      attr_accessor :usb_type
      attr_accessor :build_root
      attr_accessor :toolchain

      def initialize(main)
        main = Pathname(main)

        self.main = main
        self.libraries = []

        yield self

        raise "You have to specify a board for the sketch" unless board

        self.toolchain = Toolchain.new(self)

        self.build_root ||= "build"

        self.elf ||= build(main.basename.sub_ext(".elf"))
        self.hex ||= main.basename.sub_ext(".hex")

        self.programmer ||= "avr109"
        self.upload_rate ||= 19200

        create_tasks
      end

      def config
        Rake::Arduino.config
      end

      def core_paths
        @core_paths ||= config.cores.map{|c| Pathname(c)}.select do |core|
          board.cores.include? core.basename.to_s
        end
      end

      def library_paths
        libraries.map do |lib|
          Pathname(config.library_path) + lib
        end
      end

      def build(path)
        build_path = Pathname(build_root) + path
      end

      def compile(*source_files)
        source_files = [source_files].flatten
        object_files = source_files.map { |source| build(source.sub_ext(".o")) }

        object_files.zip(source_files).each do |object_file, source_file|
          file object_file => source_file do
            object_file.parent.mkpath
            toolchain.compile source_file, :into => object_file
          end
        end

        object_files
      end

      def create_tasks
        compiled_libraries = [
          *board.cores,
          *libraries
        ].map{|l| build("#{l}.a")}

        task :default => [*compiled_libraries, hex]

        main_objects = compile main

        (core_paths + library_paths).each do |path|
          library_out = build(path.basename.sub_ext(".a"))

          object_files = compile Pathname.glob(path +"**/*.{c,cpp}")

          file library_out => object_files do
            object_files.each do |object_file|
              library_out.parent.mkpath
              toolchain.archive object_file, :into => library_out
            end
          end
        end

        file elf => main_objects + compiled_libraries do
          toolchain.link main_objects, :with => compiled_libraries, :into => elf
        end

        file hex => elf do
          size = toolchain.convert_binary(elf, :hex => hex)

          if size > board.max_size
            puts "The sketch size (#{size} bytes) has overriden the maximum size (#{board.max_size} bytes)."
            rm hex
            exit -1
          else
            puts "Sketch size: #{size} bytes (of a #{board.max_size} bytes maximum)."
          end
        end

        task :upload => [:all, :upload_pre] do
          sh "#{avrdude} -V -F -p #{board.mcu} -c #{programmer} -P #{port} -b #{upload_rate} -D -Uflash:w:#{hex}:i"
        end

        task :clean do
          rm_rf Dir["build"]
          rm_f Dir["**/*.{o,a,hex,elf}"]
        end
      end

      def includes
        ["/usr/lib/avr/include/avr", *core_paths, *library_paths]
      end

      def defines
        ["F_CPU=#{board.cpu_speed}L", "ARDUINO=18", *board.defines]
      end

      def avrdude
        "avrdude"
      end
    end
  end
end
