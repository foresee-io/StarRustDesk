// Change appearance only; dimensions, input handlers and focus behavior stay on each button.
export class ButtonShapeModifier implements AttributeModifier<ButtonAttribute> {
  private rectangular: boolean
  private legacyRadius: number
  private legacyType: ButtonType

  constructor(rectangular: boolean, legacyRadius: number = 12, legacyType: ButtonType = ButtonType.Capsule) {
    this.rectangular = rectangular
    this.legacyRadius = legacyRadius
    this.legacyType = legacyType
  }

  applyNormalAttribute(instance: ButtonAttribute): void {
    instance.type(this.rectangular ? ButtonType.Normal : this.legacyType)
    instance.borderRadius(this.rectangular ? 12 : this.legacyRadius)
  }
}
