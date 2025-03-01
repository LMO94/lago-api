# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Events::CreateService, type: :service do
  subject(:create_service) { described_class.new }

  let(:organization) { create(:organization) }
  let(:billable_metric) { create(:billable_metric, organization:) }
  let(:customer) { create(:customer, organization:) }

  describe '#validate_params' do
    let(:params) do
      {
        transaction_id: SecureRandom.uuid,
        external_customer_id: customer.external_id,
        code: billable_metric.code,
      }
    end

    before do
      create(:active_subscription, customer:, organization:)
      allow(Events::ValidateCreationService).to receive(:call).and_call_original
    end

    it 'delegates to ValidateParamsService' do
      create_service.validate_params(organization:, params:)

      expect(Events::ValidateCreationService).to have_received(:call).with(
        organization:,
        params:,
        customer:,
        result: kind_of(BaseService::Result),
        send_webhook: false,
      )
    end

    it 'validates the presence of the mandatory arguments' do
      result = create_service.validate_params(organization:, params:)

      expect(result).to be_success
    end

    context 'with missing or nil arguments' do
      it 'returns an error' do
        params[:code] = nil
        result = create_service.validate_params(organization:, params:)

        aggregate_failures do
          expect(result).not_to be_success
          expect(result.error).to be_a(BaseService::NotFoundFailure)
          expect(result.error.message).to eq('billable_metric_not_found')
        end
      end
    end
  end

  describe '#call' do
    let(:plan) { create(:plan, organization: customer.organization) }
    let(:subscription) { create(:active_subscription, customer:, organization:, plan:) }

    let(:create_args) do
      {
        external_customer_id: customer.external_id,
        code: billable_metric.code,
        transaction_id: SecureRandom.uuid,
        properties: { foo: 'bar' },
        timestamp: Time.zone.now.to_i,
      }
    end
    let(:timestamp) { Time.zone.now.to_i }

    before { subscription }

    context 'when timestamp is not present in the payload' do
      let(:create_args) do
        {
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          external_subscription_id: subscription.external_id,
          properties: { foo: 'bar' },
        }
      end

      it 'creates an event by setting the timestamp to the current datetime' do
        result = create_service.call(organization:, params: create_args, timestamp:, metadata: {})

        expect(result).to be_success
        expect(result.event.timestamp).to eq(Time.zone.at(timestamp))
      end
    end

    context 'when timestamp is given as string' do
      it 'creates an event by setting timestamp' do
        create_args[:timestamp] = create_args[:timestamp].to_s

        result = create_service.call(organization:, params: create_args, timestamp:, metadata: {})
        expect(result).to be_success
        expect(result.event.timestamp).to eq(Time.zone.at(create_args[:timestamp].to_i))
      end
    end

    context 'when creating an event to a terminated subscription' do
      let(:subscription) do
        create(:subscription, customer:, organization:, status: :terminated, started_at: 1.month.ago)
      end

      let(:active_subscription) do
        create(
          :active_subscription,
          customer:,
          organization:,
          started_at: 1.day.ago,
          external_id: subscription.external_id,
        )
      end

      let(:create_args) do
        {
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          external_subscription_id: subscription.external_id,
          properties: { foo: 'bar' },
          timestamp: 1.week.ago.to_i,
        }
      end

      before { active_subscription }

      it 'creates an event to the terminated subscription' do
        result = create_service.call(organization:, params: create_args, timestamp:, metadata: {})
        expect(result).to be_success

        event = result.event

        aggregate_failures do
          expect(event.customer_id).to eq(customer.id)
          expect(event.organization_id).to eq(organization.id)
          expect(event.code).to eq(billable_metric.code)
          expect(event.subscription_id).to eq(subscription.id)
          expect(event.timestamp).to be_a(Time)
        end
      end
    end

    context 'when creating an event to an active subscription with the same external id' do
      let(:subscription) do
        create(:subscription, customer:, organization:, status: :terminated, started_at: 1.month.ago)
      end

      let(:active_subscription) do
        create(
          :active_subscription,
          customer:,
          organization:,
          started_at: 1.week.ago,
          external_id: subscription.external_id,
        )
      end

      let(:create_args) do
        {
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          external_subscription_id: subscription.external_id,
          properties: { foo: 'bar' },
          timestamp: 1.day.ago.to_i,
        }
      end

      before { active_subscription }

      it 'creates an event to the active subscription' do
        result = create_service.call(organization:, params: create_args, timestamp:, metadata: {})
        expect(result).to be_success

        event = result.event

        aggregate_failures do
          expect(event.customer_id).to eq(customer.id)
          expect(event.organization_id).to eq(organization.id)
          expect(event.code).to eq(billable_metric.code)
          expect(event.subscription_id).to eq(active_subscription.id)
          expect(event.timestamp).to be_a(Time)
        end
      end
    end

    context 'when customer has only one active subscription and subscription is not given' do
      it 'creates a new event and assigns subscription' do
        result = create_service.call(
          organization:,
          params: create_args,
          timestamp:,
          metadata: {},
        )

        expect(result).to be_success

        event = result.event

        aggregate_failures do
          expect(event.customer_id).to eq(customer.id)
          expect(event.organization_id).to eq(organization.id)
          expect(event.code).to eq(billable_metric.code)
          expect(event.subscription_id).to eq(subscription.id)
          expect(event.timestamp).to be_a(Time)
        end
      end
    end

    context 'when customer has only one active subscription and customer is not given' do
      let(:create_args) do
        {
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          external_subscription_id: subscription.external_id,
          properties: { foo: 'bar' },
          timestamp: Time.zone.now.to_i,
        }
      end

      it 'creates a new event and assigns customer' do
        result = create_service.call(
          organization:,
          params: create_args,
          timestamp:,
          metadata: {},
        )

        expect(result).to be_success

        event = result.event

        aggregate_failures do
          expect(event.customer_id).to eq(customer.id)
          expect(event.organization_id).to eq(organization.id)
          expect(event.code).to eq(billable_metric.code)
          expect(event.subscription_id).to eq(subscription.id)
          expect(event.timestamp).to be_a(Time)
        end
      end
    end

    context 'when customer has two active subscriptions' do
      let(:subscription2) { create(:active_subscription, customer:, organization:) }

      let(:create_args) do
        {
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          external_subscription_id: subscription2.external_id,
          properties: { foo: 'bar' },
          timestamp: Time.zone.now.to_i,
        }
      end

      before { subscription2 }

      it 'creates a new event for correct subscription' do
        result = create_service.call(
          organization:,
          params: create_args,
          timestamp:,
          metadata: {},
        )

        expect(result).to be_success

        event = result.event

        aggregate_failures do
          expect(event.subscription_id).to eq(subscription2.id)
        end
      end
    end

    context 'when event already exists' do
      let(:existing_event) do
        create(
          :event,
          organization:,
          transaction_id: create_args[:transaction_id],
          subscription_id: subscription.id,
        )
      end

      before { existing_event }

      it 'returns existing event' do
        expect do
          create_service.call(
            organization:,
            params: create_args,
            timestamp:,
            metadata: {},
          )
        end.not_to change { organization.events.count }
      end
    end

    context 'when properties are empty' do
      let(:create_args) do
        {
          external_customer_id: customer.external_id,
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          timestamp: Time.zone.now.to_i,
        }
      end

      it 'creates a new event' do
        result = create_service.call(
          organization:,
          params: create_args,
          timestamp:,
          metadata: {},
        )

        expect(result).to be_success

        event = result.event

        aggregate_failures do
          expect(event.customer_id).to eq(customer.id)
          expect(event.organization_id).to eq(organization.id)
          expect(event.code).to eq(billable_metric.code)
          expect(event.subscription_id).to eq(subscription.id)
          expect(event.timestamp).to be_a(Time)
          expect(event.properties).to eq({})
        end
      end
    end

    context 'when event matches a recurring billable metric' do
      let(:billable_metric) do
        create(
          :billable_metric,
          organization: customer.organization,
          aggregation_type: 'recurring_count_agg',
          field_name: 'item_id',
        )
      end

      let(:create_args) do
        {
          customer_id: customer.external_id,
          external_subscription_id: subscription.external_id,
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          properties: {
            billable_metric.field_name => 'ext_12345',
            'operation_type' => 'add',
          },
          timestamp: Time.zone.now.to_i,
        }
      end

      it 'creates a persisted metric' do
        expect do
          create_service.call(
            organization:,
            params: create_args,
            timestamp:,
            metadata: {},
          )
        end.to change(PersistedEvent, :count).by(1)
      end

      context 'when a validation error occurs' do
        let(:create_args) do
          {
            customer_id: customer.external_id,
            external_subscription_id: subscription.external_id,
            code: billable_metric.code,
            transaction_id: SecureRandom.uuid,
            properties: {
              'operation_type' => 'add',
            },
            timestamp: Time.zone.now.to_i,
          }
        end

        it 'returns an error and send an error webhook' do
          result = nil

          expect do
            result = create_service.call(
              organization:,
              params: create_args,
              timestamp:,
              metadata: {},
            )
          end.to have_enqueued_job(SendWebhookJob)

          expect(result).not_to be_success
        end
      end
    end

    context 'when event matches an pay_in_advance charge that is not invoiceable' do
      let(:charge) { create(:standard_charge, :pay_in_advance, plan:, billable_metric:, invoiceable: false) }
      let(:billable_metric) do
        create(
          :billable_metric,
          organization: customer.organization,
          aggregation_type: 'sum_agg',
          field_name: 'item_id',
        )
      end

      let(:create_args) do
        {
          customer_id: customer.external_id,
          external_subscription_id: subscription.external_id,
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          properties: { billable_metric.field_name => '12' },
          timestamp: Time.zone.now.to_i,
        }
      end

      before { charge }

      it 'enqueues a job to perform the pay_in_advance aggregation' do
        expect do
          create_service.call(
            organization:,
            params: create_args,
            timestamp:,
            metadata: {},
          )
        end.to have_enqueued_job(Fees::CreatePayInAdvanceJob)
      end

      context 'when charge is invoiceable' do
        before { charge.update!(invoiceable: true) }

        it 'does not enqueue a job to perform the pay_in_advance aggregation' do
          expect do
            create_service.call(
              organization:,
              params: create_args,
              timestamp:,
              metadata: {},
            )
          end.not_to have_enqueued_job(Fees::CreatePayInAdvanceJob)
        end
      end

      context 'when multiple charges have the billable metric' do
        before { create(:standard_charge, :pay_in_advance, plan:, billable_metric:, invoiceable: false) }

        it 'enqueues a job for each charge' do
          expect do
            create_service.call(
              organization:,
              params: create_args,
              timestamp:,
              metadata: {},
            )
          end.to have_enqueued_job(Fees::CreatePayInAdvanceJob).twice
        end
      end
    end

    context 'when event matches a pay_in_advance charge that is invoiceable' do
      let(:charge) { create(:standard_charge, :pay_in_advance, plan:, billable_metric:, invoiceable: true) }
      let(:billable_metric) do
        create(
          :billable_metric,
          organization: customer.organization,
          aggregation_type: 'sum_agg',
          field_name: 'item_id',
        )
      end

      let(:create_args) do
        {
          customer_id: customer.external_id,
          external_subscription_id: subscription.external_id,
          code: billable_metric.code,
          transaction_id: SecureRandom.uuid,
          properties: { billable_metric.field_name => '12' },
          timestamp: Time.zone.now.to_i,
        }
      end

      before { charge }

      it 'enqueues a job to create the pay_in_advance charge invoice' do
        expect do
          create_service.call(
            organization:,
            params: create_args,
            timestamp:,
            metadata: {},
          )
        end.to have_enqueued_job(Invoices::CreatePayInAdvanceChargeJob)
      end

      context 'when charge is not invoiceable' do
        before { charge.update!(invoiceable: false) }

        it 'does not enqueue a job to create the pay_in_advance charge invoice' do
          expect do
            create_service.call(
              organization:,
              params: create_args,
              timestamp:,
              metadata: {},
            )
          end.not_to have_enqueued_job(Invoices::CreatePayInAdvanceChargeJob)
        end
      end

      context 'when multiple charges have the billable metric' do
        before { create(:standard_charge, :pay_in_advance, plan:, billable_metric:, invoiceable: true) }

        it 'enqueues a job for each charge' do
          expect do
            create_service.call(
              organization:,
              params: create_args,
              timestamp:,
              metadata: {},
            )
          end.to have_enqueued_job(Invoices::CreatePayInAdvanceChargeJob).twice
        end
      end

      context 'when value for sum_agg is negative' do
        let(:create_args) do
          {
            customer_id: customer.external_id,
            external_subscription_id: subscription.external_id,
            code: billable_metric.code,
            transaction_id: SecureRandom.uuid,
            properties: { billable_metric.field_name => '-5' },
            timestamp: Time.zone.now.to_i,
          }
        end

        it 'does not enqueue a job' do
          expect do
            create_service.call(
              organization:,
              params: create_args,
              timestamp:,
              metadata: {},
            )
          end.not_to have_enqueued_job(Invoices::CreatePayInAdvanceChargeJob)
        end
      end

      context 'when event field name does not batch the BM one' do
        let(:create_args) do
          {
            customer_id: customer.external_id,
            external_subscription_id: subscription.external_id,
            code: billable_metric.code,
            transaction_id: SecureRandom.uuid,
            properties: { 'wrong_field_name' => '5' },
            timestamp: Time.zone.now.to_i,
          }
        end

        it 'does not enqueue a job' do
          expect do
            create_service.call(
              organization:,
              params: create_args,
              timestamp:,
              metadata: {},
            )
          end.not_to have_enqueued_job(Invoices::CreatePayInAdvanceChargeJob)
        end
      end
    end
  end
end
