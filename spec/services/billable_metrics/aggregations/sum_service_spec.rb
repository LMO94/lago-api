# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BillableMetrics::Aggregations::SumService, type: :service do
  subject(:sum_service) do
    described_class.new(
      billable_metric:,
      subscription:,
      group:,
      event: pay_in_advance_event,
    )
  end

  let(:subscription) { create(:subscription) }
  let(:organization) { subscription.organization }
  let(:customer) { subscription.customer }
  let(:group) { nil }

  let(:billable_metric) do
    create(
      :billable_metric,
      organization:,
      aggregation_type: 'sum_agg',
      field_name: 'total_count',
    )
  end

  let(:from_datetime) { Time.current - 1.month }
  let(:to_datetime) { Time.current }
  let(:options) do
    { free_units_per_events: 2, free_units_per_total_aggregation: 30 }
  end

  let(:pay_in_advance_event) { nil }

  before do
    create_list(
      :event,
      4,
      code: billable_metric.code,
      customer:,
      subscription:,
      timestamp: Time.zone.now - 1.day,
      properties: {
        total_count: 12,
      },
    )
  end

  it 'aggregates the events' do
    result = sum_service.aggregate(from_datetime:, to_datetime:, options:)

    expect(result.aggregation).to eq(48)
    expect(result.pay_in_advance_aggregation).to be_zero
    expect(result.count).to eq(4)
    expect(result.options).to eq({ running_total: [12, 24] })
  end

  context 'when options are not present' do
    let(:options) { {} }

    it 'returns an empty running total array' do
      result = sum_service.aggregate(from_datetime:, to_datetime:, options:)
      expect(result.options).to eq({ running_total: [] })
    end
  end

  context 'when option values are nil' do
    let(:options) do
      { free_units_per_events: nil, free_units_per_total_aggregation: nil }
    end

    it 'returns an empty running total array' do
      result = sum_service.aggregate(from_datetime:, to_datetime:, options:)
      expect(result.options).to eq({ running_total: [] })
    end
  end

  context 'when free_units_per_events is nil' do
    let(:options) do
      { free_units_per_events: nil, free_units_per_total_aggregation: 30 }
    end

    it 'returns running total based on per total aggregation' do
      result = sum_service.aggregate(from_datetime:, to_datetime:, options:)
      expect(result.options).to eq({ running_total: [12, 24, 36] })
    end
  end

  context 'when free_units_per_total_aggregation is nil' do
    let(:options) do
      { free_units_per_events: 2, free_units_per_total_aggregation: nil }
    end

    it 'returns running total based on per events' do
      result = sum_service.aggregate(from_datetime:, to_datetime:, options:)
      expect(result.options).to eq({ running_total: [12, 24] })
    end
  end

  context 'when events are out of bounds' do
    let(:to_datetime) { Time.zone.now - 2.days }

    it 'does not take events into account' do
      result = sum_service.aggregate(from_datetime:, to_datetime:)

      expect(result.aggregation).to eq(0)
      expect(result.count).to eq(0)
      expect(result.options).to eq({ running_total: [] })
    end
  end

  context 'when properties is not found on events' do
    before do
      billable_metric.update!(field_name: 'foo_bar')
    end

    it 'counts as zero' do
      result = sum_service.aggregate(from_datetime:, to_datetime:)

      expect(result.aggregation).to eq(0)
      expect(result.count).to eq(0)
      expect(result.options).to eq({ running_total: [] })
    end
  end

  context 'when properties is a float' do
    before do
      create(
        :event,
        code: billable_metric.code,
        customer:,
        subscription:,
        timestamp: Time.zone.now - 1.day,
        properties: {
          total_count: 4.5,
        },
      )
    end

    it 'aggregates the events' do
      result = sum_service.aggregate(from_datetime:, to_datetime:)

      expect(result.aggregation).to eq(52.5)
    end
  end

  context 'when properties is not a number' do
    before do
      create(
        :event,
        code: billable_metric.code,
        customer:,
        subscription:,
        timestamp: Time.zone.now - 1.day,
        properties: {
          total_count: 'foo_bar',
        },
      )
    end

    it 'returns a failed result' do
      result = sum_service.aggregate(from_datetime:, to_datetime:)

      aggregate_failures do
        expect(result).not_to be_success
        expect(result.error).to be_a(BaseService::ServiceFailure)
        expect(result.error.code).to eq('aggregation_failure')
        expect(result.error.error_message).to be_present
      end
    end
  end

  context 'when group_id is given' do
    let(:group) do
      create(:group, billable_metric_id: billable_metric.id, key: 'region', value: 'europe')
    end

    before do
      create(
        :event,
        code: billable_metric.code,
        customer:,
        subscription:,
        timestamp: Time.zone.now - 1.day,
        properties: {
          total_count: 12,
          region: 'europe',
        },
      )

      create(
        :event,
        code: billable_metric.code,
        customer:,
        subscription:,
        timestamp: Time.zone.now - 1.day,
        properties: {
          total_count: 8,
          region: 'europe',
        },
      )

      create(
        :event,
        code: billable_metric.code,
        customer:,
        subscription:,
        timestamp: Time.zone.now - 1.day,
        properties: {
          total_count: 12,
          region: 'africa',
        },
      )
    end

    it 'aggregates the events' do
      result = sum_service.aggregate(from_datetime:, to_datetime:, options:)

      expect(result.aggregation).to eq(20)
      expect(result.count).to eq(2)
      expect(result.options).to eq({ running_total: [12, 20] })
    end
  end

  context 'when event is given' do
    let(:pay_in_advance_event) do
      create(
        :event,
        code: billable_metric.code,
        customer:,
        subscription:,
        timestamp: Time.zone.now - 1.day,
        properties:,
      )
    end

    let(:properties) { { total_count: 12 } }

    it 'assigns a pay_in_advance aggregation' do
      result = sum_service.aggregate(from_datetime:, to_datetime:)

      expect(result.pay_in_advance_aggregation).to eq(12)
    end

    context 'when properties is a float' do
      let(:properties) { { total_count: 12.4 } }

      it 'assigns a pay_in_advance aggregation' do
        result = sum_service.aggregate(from_datetime:, to_datetime:)

        expect(result.pay_in_advance_aggregation).to eq(12.4)
      end
    end

    context 'when event propertie does not match metric field name' do
      let(:properties) { { final_count: 10 } }

      it 'assigns 0 as pay_in_advance aggregation' do
        result = sum_service.aggregate(from_datetime:, to_datetime:)

        expect(result.pay_in_advance_aggregation).to be_zero
      end
    end

    context 'when event is missing properties' do
      let(:properties) { {} }

      it 'assigns 0 as pay_in_advance aggregation' do
        result = sum_service.aggregate(from_datetime:, to_datetime:)

        expect(result.pay_in_advance_aggregation).to be_zero
      end
    end
  end
end
