# frozen_string_literal: true

module Customers
  module AppliedTaxes
    class CreateService < BaseService
      def initialize(customer:, tax:)
        @customer = customer
        @tax = tax
        super
      end

      def call
        return result.not_found_failure!(resource: 'customer') unless customer
        return result.not_found_failure!(resource: 'tax') unless tax

        applied_tax = customer.applied_taxes.find_or_create_by!(tax:)

        Invoices::RefreshBatchJob.perform_later(customer.invoices.draft.pluck(:id))

        result.applied_tax = applied_tax
        result
      end

      private

      attr_reader :customer, :tax
    end
  end
end
