module ActiveRecord
  module HasStates
    def self.included(base)
      base.extend HookMethod
    end

    class StateMachine < Hash
      attr_reader :model, :column
      
      def initialize(model, column)
        @model = model
        @column =  column
      end

      def transition(transitions)
        event = transitions.delete(:as)
        event = event.to_s if event

        transitions.each do |from,to|
          from = from.to_s
          to = to.to_s
          
          raise ArgumentError, "duplicate transition from #{from} to #{to}" if self[from].include?(to)
          
          self[from][to] = { :event => event }

          model.transitions_for(event)[from] = to if event
        end
        
        model.class_eval <<-TRANSITION, __FILE__, __LINE__
          def #{event}_transition(method)
            @from_state = self.#{column}
            @to_state = self.class.transitions_for('#{event}')[@from_state]
            return unless @to_state
            self.#{column} = @to_state
            begin
              @transitioning = true
              send(method)
            ensure
              @transitioning = false
            end
          end
          protected :#{event}_transition
        TRANSITION
        model.class_eval "def #{event}; self.#{event}_transition(:save); end", __FILE__, __LINE__
        model.class_eval "def #{event}!; self.#{event}_transition(:save!); end", __FILE__, __LINE__
      end
    end
    
    module HookMethod
      def has_states(*names, &block)
        include InstanceMethods unless self.respond_to?(:state_columns)

        options = names.extract_options!
        column = options[:in] || 'state'
        state_machine = state_machine_for(column)

        names.each do |name|
          state_machine[name.to_s] = {}
          class_eval "def #{name}?; #{column} == '#{name}'; end", __FILE__, __LINE__
          class_eval "named_scope :#{name}, :conditions => { :#{column} => '#{name}' }", __FILE__, __LINE__
          define_callbacks "before_exit_#{name}", "after_exit_#{name}", "before_enter_#{name}", "after_enter_#{name}"
        end
        
        initial_state = names.first
        
        class_eval <<-INITIALIZE, __FILE__, __LINE__
          before_create :before_enter_initial
          after_create :after_enter_initial
          
          def before_enter_initial
            errors.add("#{column}", "does not have initial value of #{initial_state}") and return false unless #{column} == '#{initial_state}'
            callback("before_enter_#{initial_state}")
          end
          
          def after_enter_initial
            callback("after_enter_#{initial_state}")
          end
        INITIALIZE

        class_eval <<-HOOK, __FILE__, __LINE__
          def create_or_update_without_callbacks
            return super unless @transitioning
            callback("before_exit_\#{@from_state}")
            callback("before_enter_\#{@to_state}")
            result = super
            callback("after_exit_\#{@from_state}")
            callback("after_enter_\#{@to_state}")
            result
          end
        HOOK
        
        state_machine.instance_eval(&block) if block_given?
      end
      
      module InstanceMethods
        def self.included(base)
          base.extend ClassMethods
        end
        
        module ClassMethods
          def state_machines
            @state_machines ||= {}
          end

          def state_machine_for(column)
            state_machines[column] ||= StateMachine.new(self, column)
          end
          
          def transitions
            @transitions ||= {}
          end
          
          def transitions_for(event)
            transitions[event] ||= {}
          end
        end
      end
    end
  end
end