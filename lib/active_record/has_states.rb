module ActiveRecord
  module HasStates
    def self.included(base)
      base.extend HookMethod
    end

    # TODO: add to list of reserved words to eliminate trouble-making state names
    RESERVED_WORDS = %w(new)
    ERRORS = {
      :illegal_transition => "cannot transition from %s state to %s state",
      :illegal_event => "cannot transition from %s state on %s event"
    }
    
    class StateMachine < Hash
      attr_reader :model, :column, :initial_state
      
      def initialize(model, column, initial_state)
        @model = model
        @column =  column
        @initial_state = initial_state
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
          def #{event}_transition(raise_error = false)
            @from_state = self.#{column}
            @to_state = self.class.transitions_for('#{event}')[@from_state]
            if ! @to_state
              message = ERRORS[:illegal_event] % [ @from_state, '#{event}' ]
              errors.add('#{column}', message)
              raise(RuntimeError, "#{column} \#{message}") if raise_error
              return false
            end
            self.#{column} = @to_state
            begin
              @#{column}_transition = true
              if raise_error
                save!
              else
                save
              end
            ensure
              @#{column}_transition = false
            end
          end
          protected :#{event}_transition
        TRANSITION
        model.class_eval "def #{event}; self.#{event}_transition; end", __FILE__, __LINE__
        model.class_eval "def #{event}!; self.#{event}_transition(true); end", __FILE__, __LINE__
      end
    end
    
    module HookMethod
      def has_states(*names, &block)
        include InstanceMethods unless self.respond_to?(:state_machines)

        options = names.extract_options!
        column = (options[:in] || 'state').to_s
        states = names.collect(&:to_s)
        reserved = states & RESERVED_WORDS
        
        if reserved.size == 1
          raise ArgumentError, "#{reserved.to_sentence} is a reserved word"
        elsif reserved.size > 1
          raise ArgumentError, "#{reserved.to_sentence} are reserved words"
        end

        initial_state = states.first

        state_machine = state_machines[column] = StateMachine.new(self, column, initial_state)
        
        states.each do |name|
          state_machine[name] = {}
          class_eval "def #{name}?; #{column} == '#{name}'; end", __FILE__, __LINE__
          class_eval "named_scope :#{name}, :conditions => { :#{column} => '#{name}' }", __FILE__, __LINE__
          define_callbacks "before_exit_#{name}", "after_exit_#{name}", "before_enter_#{name}", "after_enter_#{name}"
        end
        
        class_eval <<-INITIALIZE, __FILE__, __LINE__
          before_validation_on_create { |record| record.#{column} = '#{initial_state}' if record.#{column}.blank? }
          validates_inclusion_of :#{column}, :in => %w(#{initial_state}), :on => :create, :message => "should not have an initial state of %s"
          validates_inclusion_of :#{column}, :in => %w(#{states.join(' ')}), :on => :update
        INITIALIZE

        class_eval <<-HOOK, __FILE__, __LINE__
          def detect_transition
            return true if @#{column}_transition
            if new_record?
              @from_state = nil
              @to_state = self.#{column}
              @#{column}_transition = true
            elsif #{column}_changed?
              @from_state = self.#{column}_was
              @to_state = self.#{column}
              raise(RuntimeError, "#{column} #{ERRORS[:illegal_transition]}" % [ @from_state, @to_state ]) unless self.class.state_machines['#{column}'][@from_state][@to_state]
              @#{column}_transition = true
            end
          end
          protected :detect_transition
          
          def create_or_update_without_callbacks
            return super unless detect_transition
            callback("before_exit_\#{@from_state}") unless @from_state.nil?
            callback("before_enter_\#{@to_state}")
            result = super
            callback("after_exit_\#{@from_state}") unless @from_state.nil?
            callback("after_enter_\#{@to_state}")
            result
          end
          protected :create_or_update_without_callbacks
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