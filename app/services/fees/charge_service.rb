# frozen_string_literal: true

module Fees
  class ChargeService < BaseService
    def initialize(invoice:, charge:, subscription:, boundaries:)
      @invoice = invoice
      @charge = charge
      @subscription = subscription
      @boundaries = OpenStruct.new(boundaries)
      super(nil)
    end

    def create
      return result if already_billed?

      init_fees
      init_true_up_fee(fee: result.fees.first, amount_cents: result.fees.sum(&:amount_cents))
      return result unless result.success?

      result.fees.each(&:save!)
      result
    rescue ActiveRecord::RecordInvalid => e
      result.record_validation_failure!(record: e.record)
    end

    def current_usage
      init_fees
      result
    end

    private

    attr_accessor :invoice, :charge, :subscription, :boundaries

    delegate :customer, to: :invoice
    delegate :billable_metric, to: :charge
    delegate :plan, to: :subscription

    def init_fees
      result.fees = []

      if charge.group_properties.blank?
        init_fee(properties: charge.properties)
      else
        charge.group_properties.each do |group_properties|
          group = billable_metric.selectable_groups.find_by(id: group_properties.group_id)
          init_fee(properties: group_properties.values, group:)
        end
      end
    end

    def init_fee(properties:, group: nil)
      amount_result = compute_amount(properties:, group:)
      return result.fail_with_error!(amount_result.error) unless amount_result.success?

      # NOTE: amount_result should be a BigDecimal, we need to round it
      # to the currency decimals and transform it into currency cents
      currency = invoice.total_amount.currency
      rounded_amount = amount_result.amount.round(currency.exponent)
      amount_cents = rounded_amount * currency.subunit_to_unit

      new_fee = Fee.new(
        invoice:,
        subscription:,
        charge:,
        amount_cents:,
        amount_currency: currency,
        fee_type: :charge,
        invoiceable_type: 'Charge',
        invoiceable: charge,
        units: amount_result.units,
        properties: boundaries.to_h,
        events_count: amount_result.count,
        group_id: group&.id,
        payment_status: :pending,
        taxes_amount_cents: 0,
      )

      taxes_result = Fees::ApplyTaxesService.call(fee: new_fee)
      taxes_result.raise_if_error!

      result.fees << new_fee
    end

    def init_true_up_fee(fee:, amount_cents:)
      true_up_fee = Fees::CreateTrueUpService.call(fee:, amount_cents:).true_up_fee
      result.fees << true_up_fee if true_up_fee
    end

    def compute_amount(properties:, group: nil)
      aggregation_result = aggregator(group:).aggregate(
        from_datetime: boundaries.charges_from_datetime,
        to_datetime: boundaries.charges_to_datetime,
        options: options(properties),
      )
      return aggregation_result unless aggregation_result.success?

      apply_charge_model_service(aggregation_result, properties)
    end

    def options(properties)
      {
        free_units_per_events: properties['free_units_per_events'].to_i,
        free_units_per_total_aggregation: BigDecimal(properties['free_units_per_total_aggregation'] || 0),
      }
    end

    def already_billed?
      existing_fees = invoice.fees.where(charge_id: charge.id, subscription_id: subscription.id)
      return false if existing_fees.blank?

      result.fees = existing_fees
      true
    end

    def aggregator(group:)
      return @aggregator if @aggregator && !group

      aggregator_service = case billable_metric.aggregation_type.to_sym
                           when :count_agg
                             BillableMetrics::Aggregations::CountService
                           when :max_agg
                             BillableMetrics::Aggregations::MaxService
                           when :sum_agg
                             BillableMetrics::Aggregations::SumService
                           when :unique_count_agg
                             BillableMetrics::Aggregations::UniqueCountService
                           when :recurring_count_agg
                             BillableMetrics::Aggregations::RecurringCountService
                           else
                             raise(NotImplementedError)
      end

      @aggregator = aggregator_service.new(billable_metric:, subscription:, group:)
    end

    def apply_charge_model_service(aggregation_result, properties)
      model_service = case charge.charge_model.to_sym
                      when :standard
                        Charges::ChargeModels::StandardService
                      when :graduated
                        Charges::ChargeModels::GraduatedService
                      when :package
                        Charges::ChargeModels::PackageService
                      when :percentage
                        Charges::ChargeModels::PercentageService
                      when :volume
                        Charges::ChargeModels::VolumeService
                      else
                        raise(NotImplementedError)
      end

      model_service.apply(charge:, aggregation_result:, properties:)
    end
  end
end
