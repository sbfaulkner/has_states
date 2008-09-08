module ActiveRecord
  module HasStates
    def self.included(base)
      base.extend HookMethod
    end

    ERRORS = {
      :bad_state => "should not have a state of %s",
      :bad_initial_state => "should not have an initial state of %s",
      :bad_transition => "cannot transition from %s state to %s state",
      :bad_event => "cannot transition from %s state on %s event"
    }
    
    # class StateError < StandardError; end
    # class IllegalTransitionError < StateError; end
    # class IllegalEventError < StateError; end
    
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
        Event.new(event_name, @model, @column_name, &block).transitions.each do |from,to|
          @transitions[from] ||= []
          @transitions[from] << to
        end
      end
      
      class Event
        attr_reader :transitions, :column_name
        
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

          @model.class_eval "def #{@name}; fire('#{@name}') && save; end", __FILE__, __LINE__
          @model.class_eval "def #{@name}!; fire('#{@name}', true) && save!; end", __FILE__, __LINE__
        end

      protected
        def transition(transitions)
          transitions.each do |from,to|
            from = from.to_s
            to = to.to_s

            raise ArgumentError, "duplicate transition from #{from} to #{to}" if @transitions.include?(from)
            @transitions[from] = to
          end
          
          # model.class_eval <<-TRANSITION, __FILE__, __LINE__
          #   def #{event}_transition(raise_error = false)
          #     begin
          #       @current_event = '#{event}'
          #       to = self.class.transitions_for(@current_event)[#{column}]
          #       self.#{column} = to unless to.nil?
          #       if raise_error
          #         save!
          #       else
          #         save
          #       end
          #     ensure
          #       @current_event = nil
          #     end
          #   end
          #   protected :#{event}_transition
          # TRANSITION
          # model.class_eval "def #{event}; self.#{event}_transition; end", __FILE__, __LINE__
          # model.class_eval "def #{event}!; self.#{event}_transition(true); end", __FILE__, __LINE__
        end
      end
    end

    module HookMethod
      def has_states(*state_names, &block)
        include InstanceMethods unless self.respond_to?(:state_machines)

        options = state_names.extract_options!
        state_column = options[:in] || 'state'

        StateMachine.new(self, state_column, state_names, &block)

#         states.each do |name|
#           state_machine[name] = {}
#           class_eval "def #{name}?; #{column} == '#{name}'; end", __FILE__, __LINE__
#           class_eval "named_scope :#{name}, :conditions => { :#{column} => '#{name}' }", __FILE__, __LINE__
#           define_callbacks "before_exit_#{name}", "after_exit_#{name}", "before_enter_#{name}", "after_enter_#{name}"
#         end
#         
#         class_eval <<-INITIALIZE, __FILE__, __LINE__
#           before_validation_on_create { |record| record.#{column} = '#{initial_state}' if record.#{column}.blank? }
#           validates_state_of :#{column}
#         INITIALIZE
# 
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
        
        def fire(event_name, raise_error = false)
          event = self.class.state_events[event_name]
          column_name = event.column_name
          from = self.send(column_name)
          if to = event.transitions[from]
            self.send("#{column_name}=", to)
          else
            errors.add(column_name, ERRORS[:bad_event] % [from, event_name])
          end
        end
        
#         def detect_transitions
#           transitions = []
#           if @current_event
#             self.class.transitions_for(@current_event)
#             transitions << [self.#{column}] 
#           transitions
#         end
#         
#         def create_or_update_without_callbacks
#           transitions = detect_transitions
#           return super if transitions.empty?
#           transitions.each do |from,to|
#             callback("before_exit_#{from}") unless from.nil?
#             callback("before_enter_#{to}")
#           end
#           result = super
#           transitions.each do |from,to|
#             callback("after_exit_#{from}") unless from.nil?
#             callback("after_enter_#{to}")
#           end
#           result
#         end
        
        module ClassMethods
          def state_machines
            @state_machines ||= {}
          end
          
          def state_events
            @state_events ||= {}
          end
          
#           def transitions
#             @transitions ||= {}
#           end
#           
#           def transitions_for(event)
#             transitions[event] ||= {}
#           end

          def validates_state_of(*attr_names)
            configuration = attr_names.extract_options!
            
            bad_state = configuration[:message] || configuration[:bad_state] || ERRORS[:bad_state]
            bad_initial_state = configuration[:message] || configuration[:bad_initial_state] || ERRORS[:bad_initial_state]
            bad_transition = configuration[:message] || configuration[:bad_transition] || ERRORS[:bad_transition]

            validates_each(attr_names.collect(&:to_s), configuration) do |record,attr_name,to|
              state_machine = state_machines[attr_name]
              if state_machine.has_state?(to)
                if record.new_record?
                  record.errors.add(attr_name, bad_initial_state % to) unless state_machine.initial_state?(to)
                else
                  from = record.send("#{attr_name}_was")
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