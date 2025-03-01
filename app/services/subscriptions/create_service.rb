# frozen_string_literal: true

module Subscriptions
  class CreateService < BaseService
    def initialize(customer:, plan:, params:)
      super

      @customer = customer
      @plan = plan
      @params = params

      @name = params[:name].to_s.strip
      @subscription_at = params[:subscription_at] || Time.current
      @billing_time = params[:billing_time]
      @external_id = params[:external_id].to_s.strip

      @current_subscription = if api_context?
        editable_subscriptions&.find_by(external_id:)
      else
        editable_subscriptions&.find_by(id: params[:subscription_id])
      end
    end

    def call
      return result unless valid?(customer:, plan:, subscription_at:)

      # NOTE: in API, it's possible to create a subscription for a new customer
      customer.save! if api_context?

      ActiveRecord::Base.transaction do
        currency_result = Customers::UpdateService.new(nil).update_currency(
          customer:,
          currency: plan.amount_currency,
        )
        return currency_result unless currency_result.success?

        result.subscription = handle_subscription
      end

      track_subscription_created(result.subscription)
      result
    rescue ActiveRecord::RecordInvalid => e
      result.record_validation_failure!(record: e.record)
    rescue ArgumentError
      result.validation_failure!(errors: { billing_time: ['value_is_invalid'] })
    rescue BaseService::FailedResult => e
      e.result
    end

    private

    attr_reader :customer, :plan, :params, :name, :subscription_at, :billing_time, :external_id, :current_subscription

    def valid?(args)
      Subscriptions::ValidateService.new(result, **args).valid?
    end

    def handle_subscription
      return upgrade_subscription if upgrade?
      return downgrade_subscription if downgrade?

      current_subscription || create_subscription
    end

    def upgrade?
      return false unless current_subscription
      return false if plan.id == current_subscription.plan.id

      plan.yearly_amount_cents >= current_subscription.plan.yearly_amount_cents
    end

    def downgrade?
      return false unless current_subscription
      return false if plan.id == current_subscription.plan.id

      plan.yearly_amount_cents < current_subscription.plan.yearly_amount_cents
    end

    def create_subscription
      new_subscription = Subscription.new(
        customer:,
        plan:,
        subscription_at:,
        name:,
        external_id:,
        billing_time: billing_time || :calendar,
      )

      if new_subscription.subscription_at > Time.current
        new_subscription.pending!
      elsif new_subscription.subscription_at < Time.current
        new_subscription.mark_as_active!(new_subscription.subscription_at)
      else
        new_subscription.mark_as_active!
      end

      if new_subscription.active? && new_subscription.subscription_at.today? && plan.pay_in_advance?
        # NOTE: Since job is laucnhed from inside a db transaction
        #       we must wait for it to be commited before processing the job
        BillSubscriptionJob
          .set(wait: 2.seconds)
          .perform_later(
            [new_subscription],
            Time.zone.now.to_i,
          )
      end

      new_subscription
    end

    def upgrade_subscription
      if current_subscription.starting_in_the_future?
        update_pending_subscription

        return current_subscription
      end

      new_subscription = Subscription.new(
        customer:,
        plan:,
        name:,
        external_id: current_subscription.external_id,
        previous_subscription_id: current_subscription.id,
        subscription_at: current_subscription.subscription_at,
        billing_time: current_subscription.billing_time,
      )

      cancel_pending_subscription if pending_subscription?

      # NOTE: When upgrading, the new subscription becomes active immediatly
      #       The previous one must be terminated
      current_subscription.mark_as_terminated!
      new_subscription.mark_as_active!

      if current_subscription.plan.pay_in_advance?
        # NOTE: As subscription was payed in advance and terminated before the end of the period,
        #       we have to create a credit note for the days that were not consumed
        credit_note_result = CreditNotes::CreateFromTermination.new(subscription: current_subscription).call
        credit_note_result.raise_if_error!
      end

      # NOTE: Create an invoice for the terminated subscription
      #       if it has not been billed yet
      #       or only for the charges if subscription was billed in advance
      BillSubscriptionJob.set(wait: 2.seconds)
        .perform_later(
          [current_subscription],
          Time.zone.now.to_i + 1.second, # NOTE: Adding 1 second because of to_i rounding.
        )

      if plan.pay_in_advance?
        # NOTE: Since job is launched from inside a db transaction
        #       we must wait for it to be commited before processing the job
        BillSubscriptionJob
          .set(wait: 2.seconds)
          .perform_later(
            [new_subscription],
            Time.zone.now.to_i + 1.second, # NOTE: Adding 1 second because of to_i rounding.
          )
      end

      new_subscription
    end

    def downgrade_subscription
      if current_subscription.starting_in_the_future?
        update_pending_subscription

        return current_subscription
      end

      cancel_pending_subscription if pending_subscription?

      # NOTE: When downgrading a subscription, we keep the current one active
      #       until the next billing day. The new subscription will become active at this date
      Subscription.create!(
        customer:,
        plan:,
        name:,
        external_id: current_subscription.external_id,
        previous_subscription_id: current_subscription.id,
        subscription_at: current_subscription.subscription_at,
        status: :pending,
        billing_time: current_subscription.billing_time,
      )

      current_subscription
    end

    def pending_subscription?
      return false unless current_subscription&.next_subscription

      current_subscription.next_subscription.pending?
    end

    def cancel_pending_subscription
      current_subscription.next_subscription.mark_as_canceled!
    end

    def subscription_type
      return 'downgrade' if downgrade?
      return 'upgrade' if upgrade?

      'create'
    end

    def track_subscription_created(subscription)
      SegmentTrackJob.perform_later(
        membership_id: CurrentContext.membership,
        event: 'subscription_created',
        properties: {
          created_at: subscription.created_at,
          customer_id: subscription.customer_id,
          plan_code: subscription.plan.code,
          plan_name: subscription.plan.name,
          subscription_type:,
          organization_id: subscription.organization.id,
          billing_time: subscription.billing_time,
        },
      )
    end

    def currency_missmatch?(old_plan, new_plan)
      return false unless old_plan

      old_plan.amount_currency != new_plan.amount_currency
    end

    def update_pending_subscription
      current_subscription.plan = plan
      current_subscription.name = name if name.present?
      current_subscription.save!
    end

    def editable_subscriptions
      return nil unless customer

      @editable_subscriptions ||= customer.subscriptions.active
        .or(customer.subscriptions.starting_in_the_future)
        .order(started_at: :desc)
    end
  end
end
