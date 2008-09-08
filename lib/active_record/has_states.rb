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
      def event(event_name, &block)
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
          raise(ArgumentError, "missing from state") unless options.include?(:from)
          raise(ArgumentError, "missing to state") unless options.include?(:to)
          
          from = options[:from].to_s
          to = options[:to].to_s
          
          guard = options.include?(:guard) ? options[:guard] : true

          @transitions[from] ||= []
          @transitions[from] << Transition.new(from, to, guard)
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

#         class_eval <<-HOOK, __FILE__, __LINE__
#           def detect_transitions
#             transitions = []
#             transitions = @current_event ? self.class.transitions_for(@current_event)[self.#{column}] 
#             @from_state = self.#{column}
#             @to_state = self.class.transitions_for('#{event}')[@from_state]
#             return true if @#{column}_transition
#             if new_record?
#               @from_state = nil
#               @to_state = self.#{column}
#               true
#             elsif #{column}_changed?
#               @from_state = self.#{column}_was
#               @to_state = self.#{column}
#               # message = ERRORS[:bad_transition] % [ @from_state, @to_state]
#               # errors.add('#{column}', message)
#               # raise(IllegalTransitionError, self) unless self.class.state_machines['#{column}'][@from_state][@to_state]
#               true
#             end
#           end
#           protected :detect_transition
#           
#           def create_or_update_without_callbacks
#             return super unless detect_transition
#             callback("before_exit_\#{@from_state}") unless @from_state.nil?
#             callback("before_enter_\#{@to_state}")
#             result = super
#             callback("after_exit_\#{@from_state}") unless @from_state.nil?
#             callback("after_enter_\#{@to_state}")
#             result
#           end
#           protected :create_or_update_without_callbacks
#         HOOK
      end
      
      module InstanceMethods
        def self.included(base)
          base.extend ClassMethods
        end

        def event_for(attr_name)
          @firing_event if @firing_event && @firing_event.column_name == attr_name
        end
        
      protected
        def fire_event(event_name, save_method)
          @firing_event = self.class.state_events[event_name] || raise(ArgumentError, "unknown event: #{event_name}")
          self.send(save_method)
        ensure
          @firing_event = nil
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
              if event = record.event_for(attr_name)
                if record.send("#{attr_name}_changed?")
                  from,to = record.send("#{attr_name}_was"),state
                  record.errors.add(attr_name, conflicting_event % [from, to, event.name])
                elsif transitions = event.transitions[state]
                  if transition = transitions.find { |t| t.guard?(record) }
                    state = record.send("#{attr_name}=", transition.to_state)
                  else
                    record.errors.add(attr_name, guarded_event % [state, event.name])
                  end
                else
                  record.errors.add(attr_name, bad_event % [state, event.name])
                end
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
                record.errors.add(attr_name, bad_state % to)
              end
            end
          end
        end
      end
    end
  end
end