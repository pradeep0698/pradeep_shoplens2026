import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shoplens/data/models/product.dart';
import 'package:shoplens/presentation/widgets/product_card.dart';

Product _product({required String name, String? category, String? seller}) => Product(
      productId: name,
      name: name,
      price: 10.0,
      imageUrl: '',
      category: category,
      seller: seller,
    );

Future<void> _pump(WidgetTester tester, Widget child) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));

void main() {
  testWidgets('shows Matched when neither category nor preference terms match', (tester) async {
    await _pump(
      tester,
      ProductCard(
        product: _product(name: 'Generic Widget', category: 'Home Decor'),
        shoppingCategories: const ['Electronics'],
        preferenceTerms: const ['Nike'],
      ),
    );

    expect(find.text('Matched'), findsOneWidget);
    expect(find.text('Preferred'), findsNothing);
  });

  testWidgets('upgrades to Preferred when the product matches a saved preference term, '
      'even though its category is not one the user follows', (tester) async {
    await _pump(
      tester,
      ProductCard(
        product: _product(name: 'Apple Watch Series 12', category: 'Electronics'),
        shoppingCategories: const ['Clothing'],
        preferenceTerms: const ['Apple', 'LG'],
      ),
    );

    expect(find.text('Preferred'), findsOneWidget);
    expect(find.text('Matched'), findsNothing);
  });

  testWidgets('still shows Preferred on a category match when preferenceTerms is empty', (tester) async {
    await _pump(
      tester,
      ProductCard(
        product: _product(name: 'Office Chair', category: 'Furniture'),
        shoppingCategories: const ['Furniture'],
      ),
    );

    expect(find.text('Preferred'), findsOneWidget);
  });
}
