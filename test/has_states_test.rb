require 'test/unit'

require 'rubygems'
require 'active_record'

$:.unshift File.dirname(__FILE__) + '/../lib'
require 'active_record/has_states'

require File.dirname(__FILE__) + '/../init'

class Test::Unit::TestCase
  # def assert_queries(num = 1)
  #   $query_count = 0
  #   yield
  # ensure
  #   assert_equal num, $query_count, "#{$query_count} instead of #{num} queries were executed."
  # end
  # 
  # def assert_no_queries(&block)
  #   assert_queries(0, &block)
  # end
  
protected
  def setup_db
    stdout = $stdout

    ActiveRecord::Base.logger

    # AR keeps printing annoying schema statements
    $stdout = StringIO.new

    ActiveRecord::Schema.define(:version => 1) do
      create_table :tickets do |t|
        t.column :type, :string
        t.column :state, :string
        t.column :other_state, :string
        t.column :problem, :string
        t.column :resolution, :string
        t.column :assigned_to, :string
      end
    end
  ensure  
    $stdout = stdout
  end

  def teardown_db
    ActiveRecord::Base.connection.tables.each do |table|
      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def create(klass, options = {})
    klass.create({ :problem => 'this is a problem' }.merge(options))
  end
end

ActiveRecord::Base.establish_connection(:adapter => "sqlite3", :dbfile => ":memory:")

class Ticket < ActiveRecord::Base
  validates_presence_of :problem
end

class TicketWithState < Ticket
  has_states :open, :ignored, :active, :abandoned, :resolved do
    event :ignore do
      transition :from => :open, :to => :ignored
    end
    event :activate do
      transition :from => :open, :to => :active
    end
    event :abandon do
      transition :from => :active, :to => :abandoned
    end
    event :resolve do
      transition :from => :active, :to => :resolved
    end
  end
end

class TicketWithOtherState < Ticket
  has_states :unassigned, :assigned, :in => :other_state do
    event :assign do
      transition :from => :unassigned, :to => :assigned
    end
    event :unassign do
      transition :from => :assigned, :to => :unassigned
    end
  end
end

class TicketWithConcurrentStates < Ticket
  has_states :open, :ignored, :active, :abandoned, :resolved do
    event :ignore do
      transition :from => :open, :to => :ignored
    end
    event :activate do
      transition :from => :open, :to => :active
    end
    event :abandon do
      transition :from => :active, :to => :abandoned
    end
    event :resolve do
      transition :from => :active, :to => :resolved
    end
  end
  has_states :unassigned, :assigned, :in => :other_state do
    event :assign do
      transition :from => :unassigned, :to => :assigned
    end
    event :unassign do
      transition :from => :assigned, :to => :unassigned
    end
  end
end

class BaseTest < Test::Unit::TestCase
  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_should_create
    ticket = create(Ticket)
    assert_not_nil ticket
    assert ! ticket.new_record?, ticket.errors.full_messages.to_sentence
  end
end

class StateTest < Test::Unit::TestCase
  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_should_require_unique_states
    assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        has_states :duplicate, :duplicate
      end
    end
  end

  def test_should_require_unique_events
    assert_raises(ArgumentError) do
      Class.new(ActiveRecord::Base) do
        has_states :one, :two, :three do
          event :duplicate
          event :duplicate
        end
      end
    end
  end
  
  def test_should_create_with_state
    ticket = create(TicketWithState)
    assert_not_nil ticket
    assert ! ticket.new_record?, ticket.errors.full_messages.to_sentence
    assert ticket.open?
    assert ! (ticket.ignored? || ticket.active? || ticket.abandoned? || ticket.resolved?)
  end
  
  def test_should_not_create_with_incorrect_state
    ticket = create(TicketWithState, :state => :resolved)
    assert_not_nil ticket
    assert ticket.new_record?
    assert_not_nil ticket.errors.on(:state)
  end
  
  def test_should_not_create_with_invalid_state
    ticket = create(TicketWithState, :state => :invalid)
    assert_not_nil ticket
    assert ticket.new_record?
    assert_not_nil ticket.errors.on(:state)
  end
  
  def test_should_transition
    ticket = create(TicketWithState)
    assert ticket.open?
    assert ticket.ignore, ticket.errors.full_messages.to_sentence
    assert ticket.ignored?
    assert ticket.reload.ignored?
  end
  
  def test_should_prevent_invalid_transition
    ticket = create(TicketWithState)
    assert ticket.open?
    assert ! ticket.resolve
    assert ! ticket.resolved?
    assert_not_nil ticket.errors.on(:state)
    assert ! ticket.reload.resolved?
    assert ticket.open?
  end
  
  def test_should_prevent_invalid_transition_and_raise_error
    ticket = create(TicketWithState)
    assert ticket.open?
    assert_raises(ActiveRecord::RecordInvalid) do
      ticket.resolve!
    end
    assert ! ticket.resolved?
    assert_not_nil ticket.errors.on(:state)
    assert ! ticket.reload.resolved?
    assert ticket.open?
  end

  def test_should_detect_event_conflict
    ticket = create(TicketWithState)
    assert ticket.open?
    ticket.state = 'active'
    assert ! ticket.ignore, ticket.errors.full_messages.to_sentence
    assert ! ticket.ignored?
    assert ! ticket.reload.ignored?
    assert ticket.open?
  end
  
  def test_should_detect_transition
    ticket = create(TicketWithState)
    assert ticket.open?
    assert ticket.update_attributes(:state => 'active')
    assert ticket.active?
    assert ticket.reload.active?
  end
  
  def test_should_detect_invalid_transition
    ticket = create(TicketWithState)
    assert ticket.open?
    # TODO: in order to not cack out it will need to be dealt with in validations instead of raising it ourselves
    assert ! ticket.update_attributes(:state => 'abandoned')
    assert_not_nil ticket.errors.on(:state)
    assert ! ticket.reload.active?
    assert ticket.open?
  end
  
  def test_should_detect_invalid_transition_and_raise_error
    ticket = create(TicketWithState)
    assert ticket.open?
    assert_raises(ActiveRecord::RecordInvalid) do
      ticket.update_attributes!(:state => 'abandoned')
    end
    assert_not_nil ticket.errors.on(:state)
    assert ! ticket.reload.active?
    assert ticket.open?
  end
end

class OtherStateTest < Test::Unit::TestCase
  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_should_create_with_other_state
    ticket = create(TicketWithOtherState)
    assert_not_nil ticket
    assert ! ticket.new_record?, ticket.errors.full_messages.to_sentence
    assert ticket.unassigned?
    assert ! ticket.assigned?
  end
end

class ConcurrentStatesTest < Test::Unit::TestCase
  def setup
    setup_db
  end

  def teardown
    teardown_db
  end

  def test_should_create_with_concurrent_states
    ticket = create(TicketWithConcurrentStates)
    assert_not_nil ticket
    assert ! ticket.new_record?, ticket.errors.full_messages.to_sentence
    assert ticket.open?
    assert ! (ticket.ignored? || ticket.active? || ticket.abandoned? || ticket.resolved?)
    assert ticket.unassigned?
    assert ! ticket.assigned?
  end
end
