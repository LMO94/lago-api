# frozen_string_literal: true

class Tax < ApplicationRecord
  include PaperTrailTraceable

  has_many :applied_taxes, class_name: 'Customer::AppliedTax', dependent: :destroy
  has_many :customers, through: :applied_taxes

  has_many :fees_taxes, class_name: 'Fee::AppliedTax', dependent: :destroy
  has_many :fees, through: :fees_taxes
  has_many :invoices_taxes, class_name: 'Invoice::AppliedTax', dependent: :destroy
  has_many :invoices, through: :invoices_taxes
  has_many :credit_notes_taxes, class_name: 'CreditNote::AppliedTax', dependent: :destroy
  has_many :credit_notes, through: :credit_notes_taxes

  belongs_to :organization

  validates :name, :rate, presence: true
  validates :code, presence: true, uniqueness: { scope: :organization_id }

  scope :applied_to_organization, -> { where(applied_to_organization: true) }

  def customers_count
    applicable_customers.count
  end

  def applicable_customers
    return customers unless applied_to_organization

    # NOTE: When applied to the organization
    #       customer list = customer wihout tax + customer attached to the current tax
    customers_without_taxes_query = organization.customers.left_joins(:applied_taxes)
      .group('customers.id')
      .having('COUNT(customers_taxes.id) = 0')
      .select(:id)
    organization.customers.where(id: customers_without_taxes_query)
      .or(organization.customers.where(id: customers.select(:id)))
  end
end
