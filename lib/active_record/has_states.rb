module ActiveRecord
  module HasStates
    def self.included(base)
      base.extend HookMethod
    end

    ERRORS = {
      :bad_state => "should not have a state of %s",
      :bad_initial_state => "should not have an initial state of %s",
      :bad_transition => "cannot transition from %s state to %s state",
      :bad_event => "cannot transition from missing %s state on %s event",
      :guarded_event => "cannot transition from guarded %s state on %s event",
      :conflicting_event => "already modified from %s to %s on %s event"
    }
    
    class StateMachine
      # TODO: add to list of reserved words to eliminate trouble-making state names
      RESERVED_WORDS = %w(new)

      def initialize(model, column_name, state_names, &block)
        @model = model
        @column_name = column_name.to_s
        @state_names = []
        @transitions = {}
        
        @model.state_machines[@column_name] = self

        state_names.collect(&:to_s).each do |state_name|
          raise ArgumentError, "#{state_name} is a reserved word" if RESERVED_WORDS.include?(state_name)
          raise ArgumentError, "state name collides with #{state_name}? method" if @model.method_defined?("#{state_name}?".to_sym)
          raise ArgumentError, "state name collides with was_#{state_name}? method" if @model.method_defined?("was_#{state_name}?".to_sym)

          @state_names << state_name
          
          @model.class_eval %Q(def #{state_name}?; self.#{@column_name} == '#{state_name}'; end), __FILE__, __LINE__
          @model.class_eval %Q(def was_#{state_name}?; self.#{@column_name}_was == '#{state_name}'; end), __FILE__, __LINE__
          @model.class_eval %Q(named_scope :#{state_name}, :conditions => { :#{@column_name} => '#{state_name}' }), __FILE__, __LINE__
          @model.class_eval %Q(define_callbacks "before_exit_#{state_name}", "after_exit_#{state_name}", "before_enter_#{state_name}", "after_enter_#{state_name}"), __FILE__, __LINE__
        end
        
        @model.class_eval %Q(before_validation_on_create { |record| record.#{@column_name} = '#{@state_names.first}' if record.#{@column_name}.blank? }), __FILE__, __LINE__
        @model.class_eval %Q(validates_state_of :#{@column_name}), __FILE__, __LINE__

        @model.class_eval <<-TRANSITIONS
          def create_or_update_without_callbacks_with_#{@column_name}_transitions
            new_record = new_record?
            return create_or_update_without_callbacks_without_#{@column_name}_transitions unless new_record || #{@column_name}_changed?
            from = #{@column_name}_was
            to = #{@column_name}
            callback("before_exit_\#{from}") unless new_record
            callback("before_enter_\#{to}")
            result = create_or_update_without_callbacks_without_#{@column_name}_transitions
            callback("after_exit_\#{from}") unless new_record
            callback("after_enter_\#{to}")
            result 
          end
          
          alias_method_chain :create_or_update_without_callbacks, :#{@column_name}_transitions
        TRANSITIONS

        self.instance_eval(&block) if block_given?
      end

      def has_state?(name)
        @state_names.include?(name)
      end
      
      def initial_state?(name)
        @state_names.first == name
      end
      
      def transition?(from, to)
        @transitions[from].include?(to)
      end
      
    protected
      def on(event_name, &block)
        Event.new(event_name, @model, @column_name, &block).transitions.each do |from,from_transitions|
          @transitions[from] ||= {}
          from_transitions.each do |transition|
            @transitions[from][transition.to_state] ||= []
            @transitions[from][transition.to_state] << transition
          end
        end
      end
      
      class Event
        attr_reader :name, :transitions, :column_name
        
        def initialize(name, model, column_name, &block)
          @name = name.to_s
          @model = model
          @column_name = column_name.to_s
          @transitions = {}
          
          raise ArgumentError, "duplicate event name: #{@name}" if @model.state_events.include?(@name)
          raise ArgumentError, "event name conflicts with #{@name} method" if @model.method_defined?(@name.to_sym)
          raise ArgumentError, "event name conflicts with #{@name}! method" if @model.method_defined?("#{@name}!".to_sym)

          @model.state_events[@name] = self
          
          self.instance_eval(&block) if block_given?

          @model.class_eval "def #{@name}; fire_event('#{@name}', :save); end", __FILE__, __LINE__
          @model.class_eval "def #{@name}!; fire_event('#{@name}', :save!); end", __FILE__, __LINE__
        end

      protected
        def transition(options)
          guard = options.delete(:if) || true

          options.each do |key,value|
            from = key.to_s
            to = value.to_s

            @transitions[from] ||= []
            @transitions[from] << Transition.new(from, to, guard)
          end
        end

        class Transition
          attr_reader :to_state
          
          def initialize(from_state, to_state, guard)
            @from_state = from_state
            @to_state = to_state
            @guard = guard
          end
          
          def guard?(record)
            case @guard
            when Symbol
              record.send(@guard)
            when String
              record.instance_eval(@guard)
            when Proc, Method
              @guard.call(record)
            else
              @guard
            end
          end
        end
      end
    end

    module HookMethod
      def has_states(*state_names, &block)
        include InstanceMethods unless self.respond_to?(:state_machines)

        options = state_names.extract_options!
        state_column = options[:in] || 'state'

        StateMachine.new(self, state_column, state_names, &block)
      end
      
      module InstanceMethods
        def self.included(base)
          base.extend ClassMethods
        end

        def event_error_for(attr_name)
          @event_error if @event_error && @event_error.last.column_name == attr_name
        end
        
      protected
        def fire_event(event_name, save_method)
          event = self.class.state_events[event_name] || raise(ArgumentError, "unknown event: #{event_name}")
          attr_name = event.column_name
          if send("#{attr_name}_changed?")
            @event_error = [ :conflicting_event, event ]
          elsif transitions = event.transitions[send(attr_name)]
            if transition = transitions.find { |t| t.guard?(self) }
              state = send("#{attr_name}=", transition.to_state)
            else
              @event_error = [ :guarded_event, event ]
            end
          else
            @event_error = [ :bad_event, event ]
          end
          self.send(save_method)
        ensure
          @event_error = nil
        end

        module ClassMethods
          def state_machines
            @state_machines ||= {}
          end
          
          def state_events
            @state_events ||= {}
          end
          
          def validates_state_of(*attr_names)
            configuration = attr_names.extract_options!
            
            bad_state = configuration[:message] || configuration[:bad_state] || ERRORS[:bad_state]
            bad_initial_state = configuration[:message] || configuration[:bad_initial_state] || ERRORS[:bad_initial_state]
            bad_transition = configuration[:message] || configuration[:bad_transition] || ERRORS[:bad_transition]
            conflicting_event = configuration[:message] || configuration[:conflicting_event] || ERRORS[:conflicting_event]
            guarded_event = configuration[:message] || configuration[:guarded_event] || ERRORS[:guarded_event]
            bad_event = configuration[:message] || configuration[:bad_event] || ERRORS[:bad_event]

            validates_each(attr_names.collect(&:to_s), configuration) do |record,attr_name,state|
              error,event = record.event_error_for(attr_name)
              case error
              when :conflicting_event
                from = record.send("#{attr_name}_was")
                record.errors.add(attr_name, conflicting_event % [from, state, event.name])
              when :guarded_event
                record.errors.add(attr_name, guarded_event % [state, event.name])
              when :bad_event
                record.errors.add(attr_name, bad_event % [state, event.name])
              end
              
              state_machine = state_machines[attr_name]
              if state_machine.has_state?(state)
                if record.new_record?
                  record.errors.add(attr_name, bad_initial_state % state) unless state_machine.initial_state?(state)
                elsif record.send("#{attr_name}_changed?")
                  from,to = record.send("#{attr_name}_was"),state
                  # TODO: implement guard support to be more selective?
                  record.errors.add(attr_name, bad_transition % [from, to]) unless state_machine.transition?(from, to)
                end
              else
                record.errors.add(attr_name, bad_state % state)
              end
            end
          end
        end
      end
    end
  end
end