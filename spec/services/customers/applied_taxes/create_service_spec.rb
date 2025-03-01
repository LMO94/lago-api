# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Customers::AppliedTaxes::CreateService, type: :service do
  subject(:create_service) { described_class.new(customer:, tax:) }

  let(:organization) { create(:organization) }
  let(:customer) { create(:customer, organization:) }
  let(:tax) { create(:tax, organization:) }

  describe '#call' do
    it 'creates an applied tax' do
      expect { create_service.call }.to change(Customer::AppliedTax, :count).by(1)
    end

    it 'refreshes draft invoices' do
      draft_invoice = create(:invoice, :draft, organization:, customer:)

      expect do
        create_service.call
      end.to have_enqueued_job(Invoices::RefreshBatchJob).with([draft_invoice.id])
    end

    context 'when already applied to the customer' do
      it 'does not apply the tax once again' do
        create(:customer_applied_tax, tax:, customer:)
        expect { create_service.call }.not_to change(Customer::AppliedTax, :count)
      end
    end

    context 'when customer is not found' do
      let(:customer) { nil }

      it 'returns an error' do
        result = create_service.call

        aggregate_failures do
          expect(result).not_to be_success
          expect(result.error.error_code).to eq('customer_not_found')
        end
      end
    end

    context 'when tax is not found' do
      let(:tax) { nil }

      it 'returns an error' do
        result = create_service.call

        aggregate_failures do
          expect(result).not_to be_success
          expect(result.error.error_code).to eq('tax_not_found')
        end
      end
    end
  end
end
