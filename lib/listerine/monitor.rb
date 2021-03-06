module Listerine
  class Monitor
    attr_reader :name, :description, :environments, :notify_after, :then_notify_every, :levels, :current_environment
    HTTP_STATUS_OK = 200
    HTTP_STATUS_BAD_GATEWAY = 502

    def self.configure(&block)
      Listerine::Options.instance.configure(&block)
    end

    def initialize(&block)
      instance_eval(&block)

      # Name and assert fields are required for all monitors
      assert_field(:name)
      assert_field(:assert)

      # Add the monitor to the runner after it has been instantiated
      Listerine::Runner.instance.add_monitor(self)

      # Save the settings associated with this monitor to the persistence layer
      persistence().save_settings(self)
    end

    # Runs the monitor defined in the #assert call and returns a Listerine::Outcome.
    def run(*args)
      opts = args.extract_options!
      @current_environment = opts[:environment]

      append_to_notify = nil
      if self.disabled?
        outcome = Listerine::Outcome.new(Listerine::Outcome::DISABLED)
      else
        begin
          result = @assert.call
        rescue Exception => e
          error_string = "Uncaught exception running #{self.name}: #{e}. Backtrace: #{e.backtrace}"
          Listerine::Logger.error(error_string)
          append_to_notify = error_string
          result = false
        end

        # Ensure that we have a boolean value from the assert call.
        unless result.instance_of?(TrueClass) || result.instance_of?(FalseClass)
          raise TypeError.new("Assertions must return a boolean value. Monitor #{self.name} returned #{result} (#{result.class}).")
        end

        outcome = Listerine::Outcome.new(result)
        track_failures(outcome) do |failure_count|
          # Notify after notify_after failures, but then only notify every then_notify_every failures.
          if failure_count >= self.notify_after &&
              (failure_count == self.notify_after || ((failure_count + self.notify_after) % self.then_notify_every == 0))
            notify(append_to_notify)
          end

          if @if_failing.kind_of?(Proc)
            @if_failing.call(failure_count)
          end
        end
      end
      update_stats(outcome)
      outcome
    end

    def track_failures(outcome)
      if outcome.success?
        count = 0
      else
        count = failure_count()
        count += 1

        yield count
      end

      write(failure_count_key(), count)
    end

    def failure_count
      read(failure_count_key()).to_i || 0
    end

    # Allows you to disable a monitor
    def disable(environment = current_environment)
      persistence().disable(self.name, environment)
    end

    # Re enables a monitor
    def enable(environment = current_environment)
      persistence().enable(self.name, environment)
    end

    def write(key, value, environment = current_environment)
      persistence().write(key, value, environment)
    end

    def read(key, environment = current_environment)
      persistence().read(key, environment)
    end

    # Returns true if a monitor is disabled
    def disabled?(environment = current_environment)
      persistence().disabled?(self.name, environment)
    end

    # Notifies the recipient for this monitor's criticality level that the monitor has failed.
    def notify(append_to_body = "")
      recipient = Listerine::Options.instance.recipient(level())
      if recipient
        subject = "Monitor failure: #{name}"
        body = "Monitor failure: #{name}. Failure count: #{self.failure_count + 1}\n#{append_to_body}"

        if self.current_environment
          subject = "[#{self.current_environment.to_s.upcase}] #{subject}"
        end

        Listerine::Mailer.mail(recipient, subject, body)
      else
        Listerine::Logger.info("Not notifying because there is no recipient. Level = #{level}")
      end
    end

    # Runs some block of code if the monitor fails
    def if_failing(&block)
      @if_failing = lambda { |failure_count| instance_exec(failure_count, &block) }
    end

    def assert(&block)
      @assert = lambda { instance_eval(&block) }
    end

    # Sets the assert block that a +url+ returns 200 when hit via HTTP +method+ (default to GET)
    def assert_online(url, opts = {})
      method = opts[:method] || :get
      ignore_502 = opts[:ignore_502].nil? ? false : opts[:ignore_502]

      assert do
        begin
          rc = RestClient.__send__(method, url)
          code = rc.code
        rescue Exception => e
          if ignore_502 && e.message.include?(HTTP_STATUS_BAD_GATEWAY.to_s)
            code = HTTP_STATUS_BAD_GATEWAY
          else
            code = nil
          end
        end

        if code != HTTP_STATUS_OK
          Listerine::Logger.error("#{url} returned status code #{code}")
        end

        code == HTTP_STATUS_OK || (ignore_502 && code == HTTP_STATUS_BAD_GATEWAY)
      end
    end

    def persistence_key
      name
    end

    def failure_count_key
      "#{persistence_key()}_failures"
    end

    def persistence
      Listerine::Options.instance.persistence_layer
    end

    def update_stats(outcome, environment = current_environment)
      persistence().write_outcome(self.name, outcome, environment)
    end

    ###############
    # DSL Options #
    ###############
    def name(*val)
      get_set_property(:name, *val)
    end

    def description(*val)
      get_set_property(:description, *val)
    end

    def then_notify_every(*val)
      get_set_property(:then_notify_every, *val)
    end

    def notify_after(*val)
      get_set_property(:notify_after, *val)
    end

    def environments(*envs)
      @environments ||= []

      if envs.empty?
        @environments
      else
        @environments = envs
        envs.each do |env|
          self.class.__send__(:define_method, "#{env}?") do
            self.current_environment == env
          end
        end
      end
    end

    def is(*args)
      # TODO - clean up levels and recipients

      opts = args.extract_options!
      @levels ||= Listerine::Options.instance.levels.dup

      if args.empty?
        if @levels.length == 1 && @levels.first[:environment].nil?
          @levels.first[:level]
        else
          level = @levels.select {|l| !l[:environment].nil? && l[:environment] == self.current_environment }
          if level.empty?
            Listerine::Options::DEFAULT_LEVEL
          else
            level.first[:level]
          end
        end
      else
        name = args.first

        # If the leveling is set from Listerine::Options, then override it.
        @levels.delete_if {|l| l[:level] == name}
        if opts[:in]
          @levels << {:level => name, :environment => opts[:in]}
        else
          @levels << {:level => name}

          # Delete the default level since a new default was provided
          @levels.delete_if {|l| l[:level] == Listerine::Options::DEFAULT_LEVEL}
        end
      end
    end
    alias :level :is

    protected
    # Sets a +property+ if provided as a second argument. Otherwise, it returns the value of +property+, which defaults
    # to the value set in Listerine::Options
    def get_set_property(property, *args)
      property_as_inst = "@#{property}".to_sym

      if args.empty?
        val = instance_variable_get(property_as_inst)
        if val.nil? && Listerine::Options.instance.respond_to?(property)
          val = Listerine::Options.instance.__send__(property)
        end
        val
      else
        val = args.first
        if val.respond_to?(:strip)
          val = val.strip
        end
        instance_variable_set(property_as_inst, val)
      end
    end

    # Raises an ArgumentError if the field +field+ is not defined on the Monitor.
    def assert_field(field)
      attribute = instance_variable_get("@#{field}".to_sym)
      if attribute.nil? || (attribute.respond_to?(:empty?) && attribute.empty?)
        raise ArgumentError.new("#{field} is required for all monitors.")
      end
    end
  end
end
