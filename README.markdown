# has\_states

Add ActiveRecord integrated state machine functionality.

## WHY?

acts\_as\_state\_machine and AASM didn't feel quite right to me.

Validations and guards were redundant, transitions were not observable and
direct manipulation of state attributes did not result in transitions.

This is an attempt to make it work (the way I thought it should).

## Example

    # models/user.rb
    class User < ActiveRecord::Base
      has_states :signed_up, :unverified, :verified, :disabled do
        event :invite do
          transition :from => :signed_up, :to => :unverified
        end
        event :verify do
          transition :from => :unverified, :to => :verified
        end
        event :disabled do
          transition :from => :verified, :to => :disabled
        end
        event :enable do
          transition :from => :disabled, :to => :verified
        end
      end

      before_enter_unverified :set_verification_key
      
      ...
    end
    
    # models/user_observer.rb
    class UserObserver < ActiveRecord::Observer
      def after_enter_signed_up(user)
        UserMailer.deliver_signup_notification(user)
      end

      def after_enter_unverified(user)
        UserMailer.deliver_invitation(user)
      end

      def after_enter_verified(user)
        UserMailer.deliver_welcome(user)
      end
    end

## Installation

    $ script/plugin install git://github.com/sbfaulkner/has_states.git

## Legal

**Author:** S. Brent Faulkner <brentf@unwwwired.net>  
**License:** Copyright &copy; 2008 unwwwired.net, released under the MIT license
