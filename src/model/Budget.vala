/* Copyright 2014 Nicolas Laplante
*
* This file is part of envelope.
*
* envelope is free software: you can redistribute it
* and/or modify it under the terms of the GNU General Public License as
* published by the Free Software Foundation, either version 3 of the
* License, or (at your option) any later version.
*
* envelope is distributed in the hope that it will be
* useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
* Public License for more details.
*
* You should have received a copy of the GNU General Public License along
* with envelope. If not, see http://www.gnu.org/licenses/.
*/

using Gee;

namespace Envelope {

    /**
     * Monthly budget class used to track monthly income, expenses,
     * budgeted and available amounts.
     *
     *
     */
    public class Budget : Object, Comparable<Budget> {

        // private collections backing the transactions and categories properties
        private Gee.List<Transaction>? budget_transactions;
        private SortedSet<MonthlyCategory>? budget_categories;

        /**
         * The year of the budget
         */
        public uint year { get; construct set; }

        /**
         * The month of the budget
         */
        public uint month { get; construct set; }

        /**
         * The list of transactions in the budget's time frame
         */
        public Gee.List<Transaction>? transactions { owned get {
            if (budget_transactions == null) {
                budget_transactions = new ArrayList<Transaction> ();
            }

            return budget_transactions.read_only_view;
        } }

        /**
         * The list of categories associated to the budget's time frame
         */
        public SortedSet<MonthlyCategory>? categories { owned get {
            if (budget_categories == null) {
                budget_categories = new TreeSet<MonthlyCategory> ();
            }

            return budget_categories.read_only_view;
        } }

        /**
         * Total amount of expenses during the budget's time frame
         */
        public double outflow { get; private set; }

        /**
         * Total amount of income during the budget's time frame
         */
        public double inflow  { get; private set; }

        /**
         * Total budgeted amount in the budget's time frame
         */
        public double budgeted { get; private set; }

        /**
         * Available amouont to budget in the budget's time frame
         */
        public double available { get; private set; }

        /**
         * Emitted when a category is added to the budget
         */
        public signal void category_added (MonthlyCategory category);

        /**
         * Emitted when a category is removed from the budget
         */
        public signal void category_removed (MonthlyCategory category);

        /**
         * Emitted when the values are recalculated
         */
        public signal void recalculated ();

        /**
         * Create a new budget for the specified year and month
         *
         * @param year the year of the budget
         * @param month the month of the budget
         */
        public Budget (uint year, uint month) {
            Object ();

            this.year = year;
            this.month = month;

            outflow = inflow = budgeted = available = 0d;

            connect_signals ();
        }

        /**
         * Create a new budget for the specified time frame, with the specified transactions and categories
         *
         * @param year the year of the budget
         * @param month the month of the budget
         * @param transactions the transactions for the budget
         * @param categories the categories for the budget
         */
        public Budget.with_transactions_categories (
            uint year,
            uint month,
            Gee.List<Transaction> transactions,
            SortedSet<MonthlyCategory> categories) {

                Object ();

                this.year = year;
                this.month = month;

                this.budget_transactions = transactions;
                this.budget_categories = categories;

                double _outflow;
                double _inflow;
                double _budgeted;
                double _available;
                compute_flows (this.transactions, this.categories, out _outflow, out _inflow, out _budgeted, out _available);

                outflow = _outflow;
                inflow = _inflow;
                budgeted = _budgeted;
                available = _available;

                connect_signals ();
        }

        /**
         * Create a new budget based on another budget.
         *
         * It creates a budget for the month following the specified budget's time frame, and
         * reuses the same budgeted amounts for each category.
         *
         * @param budget the previous budget to base this budget on
         */
        public Budget.from_previous (Budget budget) {

            Object ();

            DateTime next_month;
            Envelope.Util.Date.next_month (budget.year, budget.month, out next_month);

            year = next_month.get_year ();
            month = next_month.get_month ();

            outflow = inflow = 0d;

            budgeted = budget.budgeted;
            available = -budget.budgeted;

            budget_categories = new TreeSet<MonthlyCategory> ();

            foreach (MonthlyCategory category in budget.categories) {

                var new_category = new MonthlyCategory.for_month (year, month);

                new_category.name = category.name;
                new_category.description = category.description;
                new_category.@id = category.@id;
                new_category.parent = category.parent;
                new_category.amount_budgeted = category.amount_budgeted;

                budget_categories.add (new_category);
            }

            connect_signals ();
        }

        /**
         * Add a category to the budget
         *
         * @param the category to add
         * @return bool true if the list of categories has changed, false otherwise
         */
        public bool add_category (MonthlyCategory category) {
            var changed = budget_categories.add (category);

            if (changed) {
                category_added (category);

                // connect to category's amount_budgeted property
                category.notify["amount-budgeted"].connect (on_category_amount_budgeted_changed);
            }

            return changed;
        }

        /**
         * Remove a category from the budget
         *
         * @param the category to remove
         * @return bool true if the list of categories has changed, false otherwise
         */
        public bool remove_category (MonthlyCategory category) {
            var changed = budget_categories.remove (category);

            if (changed) {
                category_removed (category);

                // disconnect category's amount_budgeted property
                category.notify["amount-budgeted"].disconnect (on_category_amount_budgeted_changed);
            }

            return changed;
        }

        /**
         * Check if the budget has the named category
         *
         * @return true if category is present, false otherwise
         */
        public bool get_category_by_name (string name, out MonthlyCategory? category = null) {

          var key = name.strip ().up ();

          foreach (MonthlyCategory cat in categories) {
            if (cat.name.up () == key) {
              category = cat;
              return true;
            }
          }

          return false;
        }

        /**
         * @see Gee.Comparable<G> : Object
         */
        public int compare_to (Budget budget) {
            if (year == budget.year) {
                if (month < budget.month) {
                    return -1;
                }

                if (month == budget.month) {
                    return 0;
                }

                return 1;
            }

            return year < budget.year ? -1 : 1;
        }

        /**
         * Internally connect some signals needed to recompute flows
         */
        private void connect_signals () {
            category_added.connect ( (category) => {
                recalculate ();
            });

            category_removed.connect ( (category) => {
                recalculate ();
            });
        }

        /**
         * Handler for category.amount_budgeted notify signal
         */
        private void on_category_amount_budgeted_changed (ParamSpec spec) {
            recalculate ();
        }

        /**
         * Shorthand method to recompute flows
         */
        private void recalculate () {

            debug ("recalculating budget %u-%u", year, month);

            double _outflow;
            double _inflow;
            double _budgeted;
            double _available;
            compute_flows (transactions, categories, out _outflow, out _inflow, out _budgeted, out _available);

            outflow = _outflow;
            inflow = _inflow;
            budgeted = _budgeted;
            available = _available;

            recalculated ();
        }

        /**
         * Calculates the total inflow, outflow, budgeted and available amounts
         * based on the list of transactions and categories.
         *
         * @param transactions  the list of transactions
         * @param categories    the list of categories
         * @param outflow       [out] total outflow
         * @param inflow        [out] total inflow
         * @param budgeted      [out] total budgeted amount
         * @param available     [out] available amount to assign to categories
         */
        private static void compute_flows (Gee.List<Transaction>? transactions,
            SortedSet<MonthlyCategory>? categories,
            out double outflow,
            out double inflow,
            out double budgeted,
            out double available) {

            outflow = inflow = available = budgeted = 0d;

            if (transactions != null && !transactions.is_empty) {
                foreach (Transaction transaction in transactions) {

                    switch (transaction.direction) {
                        case Transaction.Direction.OUTGOING:
                            outflow += Math.fabs (transaction.amount);
                            break;

                        case Transaction.Direction.INCOMING:
                            inflow += Math.fabs (transaction.amount);
                            break;

                        default:
                            assert_not_reached ();
                    }
                }
            }

            available = inflow - outflow;

            if (categories != null && !categories.is_empty) {
                foreach (MonthlyCategory category in categories) {
                    budgeted += category.amount_budgeted;
                    available -= category.amount_budgeted;
                }
            }

            debug ("compute_flows: transactions(%d), categories(%d), outflow(%.2f), inflow(%.2f), budgeted(%.2f), available(%.2f)",
              transactions != null ? transactions.size : 0,
              categories != null ? categories.size : 0,
              outflow, inflow, budgeted, available);
        }
    }
}
