module RSpec::Puppet
  module ManifestMatchers
    class Compile
      def initialize
        @failed_resource = ""
        @check_deps = false
        @cycles = []
        @error_msg = ""
      end

      def with_all_deps
        @check_deps = true
        self
      end

      def and_raise_error(error)
        @expected_error = error
        self
      end

      def matches?(catalogue)
        @catalogue = catalogue.call

        if cycles_found?
          false
        elsif @check_deps == true && missing_dependencies?
          false
        else
          @expected_error.nil?
        end
      rescue Puppet::Error => e
        @error_msg = e.message
        if @expected_error.nil?
          false
        else
          method = @expected_error.is_a?(Regexp) ? :=~ : :==
          e.message.send(method, @expected_error)
        end
      end

      def description
        case @expected_error
        when nil
          "compile into a catalogue without dependency cycles"
        when Regexp
          "fail to compile and raise an error matching #{@expected_error.inspect}"
        else
          "fail to compile and raise the error #{@expected_error.inspect}"
        end
      end

      def failure_message
        if @cycles.empty?
          if @error_msg.empty?
            case @expected_error
            when nil
              "expected that the catalogue would include #{@failed_resource}"
            when Regexp
              "expected that the catalogue would fail to compile and raise an error matching #{@expected_error.inspect}"
            else
              "expected that the catalogue would fail to compile and raise the error #{@expected_error.inspect}"
            end
          else
            "error during compilation: #{@error_msg}"
          end
        else
          "dependency cycles found: #{@cycles.join('; ')}"
        end
      end

      def failure_message_when_negated
        if @expected_error.nil?
          "expected that the catalogue would not compile but it does"
        else
          "expected that the catalogue would compile but it does not"
        end
      end

      private

      def missing_dependencies?
        retval = false

        resource_vertices = @catalogue.vertices.select { |v| v.is_a? Puppet::Resource }
        resource_vertices.each do |vertex|
          vertex.each do |param, value|
            next unless [:require, :subscribe, :notify, :before].include?(param)

            value = Array[value] unless value.is_a? Array
            value.each do |val|
              if val.is_a? Puppet::Resource
                retval = true unless resource_exists?(val, vertex)
              end
            end
          end
        end

        retval
      end

      def resource_hash
        @resource_hash ||= begin
          res_hash = {}
          @catalogue.vertices.each do |vertex|
            next unless vertex.is_a?(Puppet::Resource)

            res_hash[vertex.ref] = 1
            if vertex[:alias]
              res_hash["#{vertex.type.to_s}[#{vertex[:alias]}]"] = 1
            end

            if vertex.uniqueness_key != [vertex.title]
              res_hash["#{vertex.type.to_s}[#{vertex.uniqueness_key.first}]"] = 1
            end
          end
          res_hash
        end
      end

      def check_resource(res)
        if resource_hash[res.ref]
          true
        elsif res[:alias] && resource_hash["#{res.type.to_s}[#{res[:alias]}]"]
          true
        else
          false
        end
      end

      def resource_exists?(res, vertex)
        if check_resource(res)
          true
        else
          @failed_resource = "#{res.ref} used at #{vertex.file}:#{vertex.line} in #{vertex.ref}"
          false
        end
      end

      def cycles_found?
        Puppet::Type.suppress_provider
        cat = @catalogue.to_ral.relationship_graph
        cat.write_graph(:resources)
        if cat.respond_to? :find_cycles_in_graph
          find_cycles(cat)
        else
          find_cycles_legacy(cat)
        end
        Puppet::Type.unsuppress_provider

        !@cycles.empty?
      end

      def find_cycles(catalogue)
        cycles = catalogue.find_cycles_in_graph
        return if cycles.empty?

        cycles.each do |cycle|
          paths = catalogue.paths_in_cycle(cycle)
          @cycles << (paths.map { |path| '(' + path.join(" => ") + ')'}.join("\n") + "\n")
        end
      end

      def find_cycles_legacy(catalogue)
        catalogue.topsort
      rescue Puppet::Error => e
        @cycles = [e.message.rpartition(';').first.partition(':').last]
      end
    end
  end
end
